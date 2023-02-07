#!/bin/bash

set -e

DIR=$(dirname "$0")

# shellcheck source=migrate-3-to-4/preflight.sh
source "$DIR"/preflight.sh
# # shellcheck source=migrate/3.0-postgres.sh
# source "$DIR"/3.0-postgres.sh
# # shellcheck source=migrate/3.0-mongo.sh
# source "$DIR"/3.0-mongo.sh
# # shellcheck source=migrate/3.0-vault.sh
# source "$DIR"/3.0-vault.sh
# # shellcheck source=migrate/3.0-bottoken.sh
# source "$DIR"/3.0-bottoken.sh
# # shellcheck source=migrate/3.0-scale.sh
# source "$DIR"/3.0-scale.sh
# # shellcheck source=migrate/3.0-key.sh
# source "$DIR"/3.0-key.sh

export BACKUP_DIR="circleci_export"
export VAULT_BU="${BACKUP_DIR}/vault"
export MONGO_BU="${BACKUP_DIR}"
export PG_BU="${BACKUP_DIR}"

ARGS="${*:1}"

# Init

help_init_options() {
    # Help message for Init menu
    echo "  -h|--help                     Print help text"
}

init_options() {
    # Handles arguments passed into the init menu
    POSITIONAL=()
    while [[ $# -gt 0 ]]
    do
    key="${1}"
    case $key in
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

    echo "done"

    # if [ ! "$SKIP_MONGO $SKIP_POSTGRES $SKIP_VAULT" = "true true true" ];
    # then
    #     echo "...scaling application deployments to 0..."
    #     scale_deployments 0

    #     # if postgres is internal, delete pod to clear any remaining connections
    #     if [ ! "$SKIP_POSTGRES" = "true" ];
    #     then
    #         kubectl delete pod -l app.kubernetes.io/name=postgresql -n "$NAMESPACE"
    #     fi

    #     # wait one minute for pods to scale down
    #     sleep 60
    # fi

    # if [ ! "$SKIP_MONGO" = "true" ];
    # then
    #     MONGO_BU="${BACKUP_DIR}/circleci-mongo-export"
    #     import_mongo

    #     reinject_bottoken
    # fi

    # if [ ! "$SKIP_POSTGRES" = "true" ];
    # then
    #     PG_BU="${BACKUP_DIR}/circleci-pg-export"
    #     import_postgres
    # fi

    # if [ ! "$SKIP_VAULT" = "true" ];
    # then
    #     VAULT_BU="${BACKUP_DIR}/circleci-vault"
    #     import_vault
    # fi

    # if [ ! "$SKIP_MONGO $SKIP_POSTGRES $SKIP_VAULT" = "true true true" ];
    # then
    #     echo "...scaling application deployments to 1..."
    #     scale_deployments 1
    # fi

    # echo "CircleCI Server Import Complete"

    # scale_reminder
    # key_reminder
}


# shellcheck disable=SC2086
init_options $ARGS
circleci_database_import
