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

DIR=$(dirname $0)

source $DIR/3.0-preflight.sh
source $DIR/3.0-postgres.sh
source $DIR/3.0-mongo.sh
source $DIR/3.0-vault.sh
source $DIR/3.0-bottoken.sh
source $DIR/3.0-scale.sh
source $DIR/3.0-key.sh

BACKUP_DIR="circleci_export"
KEY_BU="${BACKUP_DIR}/circle-data"
VAULT_BU="${BACKUP_DIR}/circleci-vault"
MONGO_BU="${BACKUP_DIR}/circleci-mongo-export"
PG_BU="${BACKUP_DIR}/circleci-pg-export"

ARGS="${@:1}"

# Init

help_init_options() {
    # Help message for Init menu
    echo "  -s|--skip-databases           Skip migrating Postgres and Mongodb data"
    echo "  -p|--skip-postgres            Skip migrating Postgres data"
    echo "  -m|--skip-mongo               Skip migrating Mongodb data"
    echo "  -v|--skip-vault               Skip migrating Vault data"
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
            SKIP_POSTGRES="true"
            SKIP_MONGO="true"
            shift # past argument
        ;;
        -p|--skip-postgres)
            SKIP_POSTGRES="true"
            shift # past argument
        ;;
        -m|--skip-mongo)
            SKIP_MONGO="true"
            shift # past argument
        ;;
        -v|--skip-vault)
            SKIP_VAULT="true"
            shift # past argument
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

    if [ ! "$SKIP_MONGO $SKIP_POSTGRES $SKIP_VAULT" = "true true true" ];
    then
        echo "...scaling application deployments to 0..."
        scale_deployments 0
        
        # wait one minute for pods to scale down
        sleep 60
    fi

    if [ ! "$SKIP_MONGO" = "true" ];
    then
        MONGO_BU="${BACKUP_DIR}/circleci-mongo-export"
        import_mongo
    fi
    
    if [ ! "$SKIP_POSTGRES" = "true" ];
    then
        PG_BU="${BACKUP_DIR}/circleci-pg-export"
        import_postgres
    fi

    if [ ! "$SKIP_VAULT" = "true" ];
    then
        VAULT_BU="${BACKUP_DIR}/circleci-vault"
        import_vault
    fi

    if [ ! "$SKIP_MONGO $SKIP_POSTGRES $SKIP_VAULT" = "true true true" ];
    then
        reinject_bottoken

        echo "...scaling application deployments to 1..."
        scale_deployments 1
    fi

    echo "CircleCI Server Import Complete"
    key_reminder
}

init_options $ARGS
circleci_database_import
