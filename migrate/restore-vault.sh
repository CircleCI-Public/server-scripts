#!/bin/bash

##
# include scripts
##
source 3.0-preflight.sh
source 3.0-vault.sh
source 3.0-bottoken
source 3.0-scale
source 3.0-key

##
# CircleCI Database Import Script
#
#   * Intended only for use with installations of CircleCI Server 3.0.
#
#   This script will import data from a CircleCI Server 2.19.x instance
#   given the tarball called `circleci_export.tar.gz` has already been
#   extracted.
#
#   Application deployments will be scaled to zero and then to one.
#   Please note a replica of 1 is not desirable for output-processor.
##

set -e

BACKUP_DIR="circleci_export"
KEY_BU="${BACKUP_DIR}/circle-data"
VAULT_BU="${BACKUP_DIR}/circleci-vault"

NAMESPACE=$1

function circleci_database_import() {
    echo "Starting CircleCI Vault Import"

    vault_preflight_checks

    echo "...scaling application deployments to 0..."
    scale_deployments 0

    # wait one minute for pods to scale down
    sleep 60

    import_vault

    reinject_bottoken

    echo "...scaling application deployments to 1..."
    scale_deployments 1

    echo "CircleCI Server Import Complete"

    key_reminder
}

circleci_database_import
