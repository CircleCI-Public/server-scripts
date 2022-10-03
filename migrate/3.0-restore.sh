#!/bin/bash

##
# CircleCI Database Import Script
#
#   * Intended only for use with installations of CircleCI Server 3.x.
#
#   This script will import data from a CircleCI Server 2.19.x instance
#   given the tarball called `circleci_export.tar.gz` has already been
#   extracted.
#
#   Application deployments will be scaled to zero and then to one.
#   Please note a replica of 1 is not desirable for output-processor.
##

set -e

DIR=$(dirname "$0")

# shellcheck source=migrate/3.0-preflight.sh
source "$DIR"/3.0-preflight.sh
# shellcheck source=migrate/3.0-postgres.sh
source "$DIR"/3.0-postgres.sh
# shellcheck source=migrate/3.0-mongo.sh
source "$DIR"/3.0-mongo.sh
# shellcheck source=migrate/3.0-vault.sh
source "$DIR"/3.0-vault.sh
# shellcheck source=migrate/3.0-bottoken.sh
source "$DIR"/3.0-bottoken.sh
# shellcheck source=migrate/3.0-scale.sh
source "$DIR"/3.0-scale.sh
# shellcheck source=migrate/3.0-key.sh
source "$DIR"/3.0-key.sh

export BACKUP_DIR="circleci_export"
export KEY_BU="${BACKUP_DIR}/circle-data"
export VAULT_BU="${BACKUP_DIR}/circleci-vault"
export MONGO_BU="${BACKUP_DIR}/circleci-mongo-export"
export PG_BU="${BACKUP_DIR}/circleci-pg-export"

ARGS="${*:1}"

# Init

help_init_options() {
    # Help message for Init menu
    echo "  -s|--skip-databases           Skip migrating Postgres and Mongodb data"
    echo "  -p|--skip-postgres            Skip migrating Postgres data"
    echo "  -m|--skip-mongo               Skip migrating Mongodb data"
    echo "  -v|--skip-vault               Skip migrating Vault data"
    echo "  --server4                     Use when migrating to 4.x"
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
        --server4)
            SERVER4="true"
            shift # past argument
        ;;
        -h|--help)
            help_init_options
            exit 0
        ;;
        -*)     # unknown option
            if [ -n "$1" ] ;
            then
                POSITIONAL+=("${1}") # save it in an array for later
            fi
            shift
        ;;
        *)          # namespace
            export NAMESPACE
            NAMESPACE=$(echo "${1}" | xargs)
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

        # if postgres is internal, delete pod to clear any remaining connections
        if [ ! "$SKIP_POSTGRES" = "true" ];
        then
            kubectl delete pod -l app.kubernetes.io/name=postgresql -n "$NAMESPACE"
        fi
        
        # wait one minute for pods to scale down
        sleep 60
    fi

    if [ ! "$SKIP_MONGO" = "true" ];
    then
        MONGO_BU="${BACKUP_DIR}/circleci-mongo-export"
        import_mongo

        # reinject_bottoken
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
        echo "...scaling application deployments to 1..."
        scale_deployments 1
    fi

    echo "CircleCI Server Import Complete"

    scale_reminder
    key_reminder
}


# shellcheck disable=SC2086
init_options $ARGS
circleci_database_import
