#!/bin/bash

set -e

DIR=$(dirname "$0")

# shellcheck source=migrate-3-to-4/preflight.sh
source "$DIR"/preflight.sh
# shellcheck source=migrate-3-to-4/postgres.sh
source "$DIR"/postgres.sh
# shellcheck source=migrate-3-to-4/mongo.sh
source "$DIR"/mongo.sh
# shellcheck source=migrate-3-to-4/vault.sh
source "$DIR"/vault.sh
# shellcheck source=migrate-3-to-4/bottoken.sh
source "$DIR"/bottoken.sh
# shellcheck source=migrate-3-to-4/scale.sh
source "$DIR"/scale.sh
# # shellcheck source=migrate/3.0-key.sh
# source "$DIR"/3.0-key.sh

export BACKUP_DIR="circleci_export"
export VAULT_BU="${BACKUP_DIR}"
export MONGO_BU="${BACKUP_DIR}/circle-mongo"
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

    scale_deployments 0

    # delete pod to clear any remaining connections
    kubectl delete pod -l app.kubernetes.io/name=postgresql -n "$NAMESPACE"

    # wait one minute for pods to finish scaling down
    sleep 60

    import_mongo

    reinject_bottoken

    import_postgres

    import_vault

    scale_deployments 1

    # scale_reminder
    # key_reminder
}


# shellcheck disable=SC2086
init_options $ARGS
circleci_database_import
