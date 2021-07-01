#!/bin/bash

##
# CircleCI Database Export Script
#
#   This script is for installations running the latest CircleCI server 2.19.x.
#
#   This script will create a tar ball of the PostgreSQL and Mongo databases.
#   This should generally be used when you are planning on switching from
#   the default embedded databases to an external database source.
#
#   This script will also archive application data for:
#   Vault
#   CircleCI encryption & signing keys
#
#   This script should be run as root from the CircleCI Services Box. CircleCI and any
#   additional postgresql or mongo containers should be shut down to eliminate
#   any chances of data corruption.
##

set -e

##
# Import individual scripts/functions
##

source 2.19-preflight.sh
source 2.19-postgres.sh
source 2.19-mongo.sh
source 2.19-vault.sh
source 2.19-key.sh
source 2.19-compress.sh

# Constants
DATE=$(date +"%Y-%m-%d-%s")
MONGO_DATA="/data/circle/mongo"
MONGO_VERSION="3.6.6"
TMP_MONGO="circle-mongo-export"
PGDATA="/data/circle/postgres/9.5/data"
PGVERSION="9.5.8"
TMP_PSQL="circle-postgres-export"
KEY_BU="circle-data"

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
        *)    # unknown option
            POSITIONAL+=("${1}") # save it in an array for later
            shift # past argument
        ;;
    esac
    done

    if [ ${#POSITIONAL[@]} -gt 0 ]
    then
        help_init_options
        exit 1
    fi
}

##
# Main function
##
function circleci_database_export() {
    echo "Starting CircleCI Database Export"

    preflight_checks

    if [ ! "$SKIP_MONGO" = "true" ];
    then
        MONGO_BU="circleci-mongo-export"
        start_mongo
        export_mongo
        check_mongo
        stop_mongo
    fi
    
    if [ ! "$SKIP_POSTGRES" = "true" ];
    then
        PG_BU="circleci-pg-export"
        start_postgres
        export_postgres
        check_postgres
        stop_postgres
    fi

    if [ ! "$SKIP_VAULT" = "true" ];
    then
        VAULT_BU="circleci-vault"
        export_vault
    fi

    export_keys

    compress

    echo "CircleCI Server Export Complete."
    echo "Your exported files can be found at $(pwd)/circleci_export.tar.gz"
}

init_options $ARGS
circleci_database_export