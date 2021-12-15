#!/usr/bin/env bash
set -xeuo pipefail

# Load database dumps for the largest databases to save time
./load-db.sh edxapp
./load-db.sh edxapp_csmh

# Bring edxapp containers online
docker-compose up -d lms studio

# Re-run edx-platform's setup.py.
# Prevents 'RuntimeError: Model class < some model > doesn't declare an explicit app_label and isn't in an
# application in INSTALLED_APPS.' from happening during migrations.
# It's not totally clear why this is necessary to do again during provisioning, as one would
# think requirements installation from the Dockerfile would take care of running setup.py.
# This is only necessary for the experimental image, but it's fast and harmless for the stable image.
# TODO: figure out why this is necessary.
docker-compose exec -T lms    bash -e -c 'pip install -e . && pip install -e common/lib/xmodule'
docker-compose exec -T studio bash -e -c 'pip install -e . && pip install -e common/lib/xmodule'

# Run edxapp migrations first since they are needed for the service users and OAuth clients
docker-compose exec -T lms bash -e -c /openedx/bin/edxapp-migrate-lms
docker-compose exec -T studio bash -e -c /openedx/bin/edxapp-migrate-cms

# Create demo course and users, including a staff and superuser.
docker-compose exec -T studio /openedx/bin/edxapp-provision-demo-course
docker-compose exec -T lms    /openedx/bin/edxapp-provision-demo-users

# Create an enterprise service user for edxapp and give them appropriate permissions
docker-compose exec -T lms bash -e -c './manage.py lms manage_user enterprise_worker enterprise_worker@example.com --staff'
docker-compose exec -T lms bash -e -c './manage.py lms shell' < enterprise/worker_permissions.py

# Enable the LMS-E-Commerce integration
docker-compose exec -T lms bash -e -c './manage.py lms configure_commerce'

# Create static assets for both LMS and Studio (assets are saved to a shared volume, hence only one command).
docker-compose exec -T lms /openedx/bin/edxapp-update-assets

# Allow LMS SSO for Studio
./provision-experimental/lms-service-users.sh studio 18010

# Provision a retirement service account user
./provision-experimental/retirement-user.sh retirement retirement_service_worker

# TODO: Disabling this for now while iterating.
# Add demo program
# ./programs/provision.sh lms
