#!/bin/bash

##
# import individual scripts/functions
##

source 2.19-preflight.sh
source 2.19-postgres.sh
source 2.19-mongo.sh
source 2.19-vault.sh

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
SKIP_DATABASE_EXPORT="false"
MONGO_VERSION="3.6.6"


# Constants
DATE=$(date +"%Y-%m-%d-%s")
MONGO_DATA="/data/circle/mongo"
MONGO_BU="circleci-mongo-export"
TMP_MONGO="circle-mongo-export"
PG_BU="circleci-pg-export"
PGDATA="/data/circle/postgres/9.5/data"
PGVERSION="9.5.8"
TMP_PSQL="circle-postgres-export"
KEY_BU="circle-data"
VAULT_BU="circleci-vault"

##
# Main function
##
function circleci_database_export() {
    echo "Starting CircleCI Database Export"

    vault-preflight_checks

    archive_data

    compress


    echo "CircleCI Server Export Complete."
    echo "Your exported files can be found at $(pwd)/circleci_export.tar.gz"
}

circleci_database_export