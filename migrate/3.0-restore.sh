#!/bin/bash

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

source 3.0-preflight.sh
source 3.0-postgres.sh
source 3.0-mongo.sh
source 3.0-vault.sh
source 3.0-bottoken
source 3.0-scale
source 3.0-key

BACKUP_DIR="circleci_export"
KEY_BU="${BACKUP_DIR}/circle-data"
VAULT_BU="${BACKUP_DIR}/circleci-vault"
MONGO_BU="${BACKUP_DIR}/circleci-mongo-export"
PG_BU="${BACKUP_DIR}/circleci-pg-export"

# Init

help_init_options() {
    # Help message for Init menu
    echo "  -s|--skip-databases           Skip importing Postgres and Mongodb data locally"
    echo "  -h|--help                     Print help text"
}

init_options() {
    # Handles arguments passed into the init menu
    POSITIONAL=()
    while [[ $# -gt 0 ]]
    do
    key="${1}"
    case $key in
        -s|--skip-databases)
            SKIP_DATABASE_IMPORT="true"
            shift
        ;;
        -h|--help)
            help_init_options
            exit 0
        ;;
        -*|--*)     # unknown option
            POSITIONAL+=("${1}") # save it in an array for later
            shift
        ;;
        *)          # namespace
            NAMESPACE=${1}
            shift
        ;;
    esac
    done

    if [ ${#POSITIONAL[@]} -gt 0 ]
    then
        help_init_options
        exit 1
    fi
}

function circleci_database_import() {
    echo "Starting CircleCI Database Import"

    preflight_checks

    echo "...scaling application deployments to 0..."
    scale_deployments 0

    # wait one minute for pods to scale down
    sleep 60

    if [ ! "$SKIP_DATABASE_IMPORT" = "true" ];
    then
        import_postgres
        import_mongo
    fi
    
    import_vault

    reinject_bottoken

    echo "...scaling application deployments to 1..."
    scale_deployments 1

    echo "CircleCI Server Import Complete"
    key_reminder
}

circleci_database_import
