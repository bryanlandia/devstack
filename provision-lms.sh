#!/usr/bin/env bash
# TODO:
#  This script is in a state of dual-support for both the 'stable' LMS devstack image
#  (edxops/edxapp) and the 'experimental' image (openedx/lms-dev). Once we're fully
#  switched to openedx/lms-dev, this script can be tidied up. For example:
#    * /edx/ can be changed to /openedx/ (on the experimental image, /edx/ is linked to /openedx/)
#    * `cd /edx/app/edxapp/edx-platform` can be removed (it's the default dir on the experimental image)
#    * paver commands can be replaced with calls to the underlying python/shell scripts.

set -eu -o pipefail
set -x

if $USE_EXPERIMENTAL_EDX_PLATFORM_IMAGES ; then
    echo -e "${YELLOW} Using experimental lms provisioning script... ${NC}"
    provision-experimental/lms.sh
    exit 0
fi

apps=( lms studio )

studio_port=18010

# Load database dumps for the largest databases to save time
./load-db.sh edxapp
./load-db.sh edxapp_csmh

# Bring edxapp containers online
for app in "${apps[@]}"; do
    docker-compose up -d $app
done

# Reinstall requirements.
# TODO: This is a total no-op in the experimental image because we set NO_PREREQ_INSTALL=1 in the
# environment & dev requirements into the virtual env at build time. It can be removed once we are
# only using the experimental image.
docker-compose exec -T lms bash -e -c 'source /edx/app/edxapp/edxapp_env && cd /edx/app/edxapp/edx-platform && NO_PYTHON_UNINSTALL=1 paver install_prereqs'
docker-compose restart lms #Installing prereqs crashes the process

# Re-run edx-platform's setup.py.
# Prevents 'RuntimeError: Model class < some model > doesn't declare an explicit app_label and isn't in an
# application in INSTALLED_APPS.' from happening during migrations.
# It's not totally clear why this is necessary to do again during provisioning, as one would
# think requirements installation from the Dockerfile would take care of running setup.py.
# This is only necessary for the experimental image, but it's fast and harmless for the stable image.
# TODO: figure out why this is necessary.
docker-compose exec -T lms bash -e -c 'source /edx/app/edxapp/edxapp_env && cd /edx/app/edxapp/edx-platform && pip install -e .'

# Run edxapp migrations first since they are needed for the service users and OAuth clients
docker-compose exec -T lms bash -e -c 'source /edx/app/edxapp/edxapp_env && cd /edx/app/edxapp/edx-platform && paver update_db --settings devstack_docker'

# Create a superuser for edxapp
# TODO: In the experimental image, /edx/bin/edxapp-provision-demo-data provisions an edx@example.com superuser,
# making these lines redundant.
docker-compose exec -T lms bash -e -c 'source /edx/app/edxapp/edxapp_env && python /edx/app/edxapp/edx-platform/manage.py lms --settings=devstack_docker manage_user edx edx@example.com --superuser --staff'
docker-compose exec -T lms bash -e -c 'source /edx/app/edxapp/edxapp_env && echo "from django.contrib.auth import get_user_model; User = get_user_model(); user = User.objects.get(username=\"edx\"); user.set_password(\"edx\"); user.save()" | python /edx/app/edxapp/edx-platform/manage.py lms shell  --settings=devstack_docker'

# Create an enterprise service user for edxapp and give them appropriate permissions
./enterprise/provision.sh

# Enable the LMS-E-Commerce integration
docker-compose exec -T lms bash -e -c 'source /edx/app/edxapp/edxapp_env && python /edx/app/edxapp/edx-platform/manage.py lms --settings=devstack_docker configure_commerce'

# Create demo course and users, including a staff and superuser.
# TODO: To support both the stable and the experimenta images, we must
#   check whether the new non-Ansible demo data provisioning scripts exist.
#   If they don't both exist, we fall back to the Ansible playbook. Once we're fully using
#   the openedx image, we can remove this branching logic and instead just invoke
#   /openedx/bin/edxapp-provision-demo-*.
if \
    docker-compose exec -T studio bash -e -c "[[ -f /openedx/bin/edxapp-provision-demo-course ]]" && \
    docker-compose exec -T lms    bash -e -c "[[ -f /openedx/bin/edxapp-provision-demo-users  ]]" ;  \
then
    docker-compose exec -T studio bash -e -c "source ../edxapp_env && pip install -e common/lib/xmodule"
    docker-compose exec -T studio /openedx/bin/edxapp-provision-demo-course
    docker-compose exec -T lms    /openedx/bin/edxapp-provision-demo-users
else
    docker-compose exec -T lms bash -e -c '/edx/app/edx_ansible/venvs/edx_ansible/bin/ansible-playbook /edx/app/edx_ansible/edx_ansible/playbooks/demo.yml -v -c local -i "127.0.0.1," --extra-vars="COMMON_EDXAPP_SETTINGS=devstack_docker"'
fi


# Fix missing vendor file by clearing the cache, if it exists.
docker-compose exec -T lms bash -e -c 'rm -f /edx/app/edxapp/edx-platform/.prereqs_cache/Node_prereqs.sha1'

# Create static assets for both LMS and Studio
# TODO: this can be replaced with `docker-compose exec -T lms /openedx/bin/edxapp-update-assets` we're on the experimental image.
for app in "${apps[@]}"; do
    docker-compose exec -T $app bash -e -c 'source /edx/app/edxapp/edxapp_env && cd /edx/app/edxapp/edx-platform && paver update_assets --settings devstack_docker'
done

# Allow LMS SSO for Studio
./provision-ida-user.sh studio studio "$studio_port"

# Provision a retirement service account user
./provision-retirement-user.sh retirement retirement_service_worker

# Add demo program
./programs/provision.sh lms
