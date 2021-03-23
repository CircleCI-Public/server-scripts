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
# Preflight checks
#   make sure script is running as root
#   make sure circle, mongo, and postgres are shut down
##
function preflight_checks() {

    if [ $(id -u) -ne 0 ]
    then
        echo "Please run this script as root"
        exit 1

    elif [ -n "$(docker ps | grep circleci-frontend | head -n1 )" ]
    then
        echo "Please shut down CircleCI from the replicated console at https://<YOUR_CIRCLE_URL>:8800 before running this script."
        exit 1

    elif [ -n "$(docker ps | grep mongo | head -n1 )" ]
    then
        echo "Please shut down any other Mongo containers before running this script"
        exit 1

    elif [ -n "$(docker ps | grep -v replicated | grep postgres | head -n1 )" ]
    then
        echo "Please shut down any other PostgreSQL containers before running this script"
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo ... installing jq
        apt-get update
        apt-get install -y jq
    fi
}

##
# Start temporary postgreSQL container with mounted data volumen
##
function start_postgres() {
    echo ... starting new postgres container with existing volume
    docker run --name $TMP_PSQL -d -v $PGDATA:/var/lib/postgresql/data postgres:$PGVERSION
}

##
# Stop the PostgreSQL container that we created with the start_postgres function
##
function stop_postgres() {
    echo ... stopping postgresql container
    docker rm -f $TMP_PSQL
}

##
# Export PostgreSQL database once the container has started and is accepting connections
##
function export_postgres() {
    echo ... exporting postgresql database
    mkdir -p $PG_BU
    pushd $PG_BU
    until docker exec $TMP_PSQL psql -U postgres -c '\l'; do
        >&2 echo "Postgres is starting up ... will try again momentarily"
        sleep 3
    done

    docker exec $TMP_PSQL pg_dumpall -U postgres -c > circle.sql
    popd
}

##
# Basic sanity check / smoke test to ensure that the postgresql export performed by
# the export_postgres function contains what we expect it to contain
##
function check_postgres() {
    echo ... verifying postgres export file
    pushd $PG_BU
    if [ -z "$(cat circle.sql | grep circle_migrations | head -n1)" ]
    then
        echo "[FATAL] Something is wrong with the postgresql export file for 'circle' database, please contact CircleCI support at enterprise-support@circleci.com for further assistance."
        stop_postgres
        exit 1
    fi
    if [ -z "$(cat circle.sql | grep build_jobs | head -n1)" ]
    then
        echo "[FATAL] Something is wrong with the postgresql export file for 'conductor_production' database, please contact CircleCI support at enterprise-support@circleci.com for further assistance."
        stop_postgres
        exit 1
    fi
    if [ -z "$(cat circle.sql | grep contexts | head -n1)" ]
    then
        echo "[FATAL] Something is wrong with the postgresql export file for 'contexts_service_production' database, please contact CircleCI support at enterprise-support@circleci.com for further assistance."
        stop_postgres
        exit 1
    fi
    if [ -z "$(cat circle.sql | grep qrtz_blob_triggers | head -n1)" ]
    then
        echo "[FATAL] Something is wrong with the postgresql export file for 'cron_service_production' database, please contact CircleCI support at enterprise-support@circleci.com for further assistance."
        stop_postgres
        exit 1
    fi
    if [ -z "$(cat circle.sql | grep tasks | head -n1)" ]
    then
        echo "[WARN] 'vms' database was not correctly exported."
    fi
    popd
}

##
# Start temporary Mongo container with mounted data volume
##
function start_mongo() {
    echo ... starting new mongo container with existing volume
    docker run --rm --name $TMP_MONGO -d -v $MONGO_DATA:/data/db mongo:$MONGO_VERSION
}

##
# Stop the Mongo container tht we created with the start_mongo function
##
function stop_mongo() {
    echo ... stopping mongo container
    docker rm -f $TMP_MONGO
}

##
# Export Mongo database once the container has started and is accepting connections
##
function export_mongo() {
    echo ... exporting mongo database

    until docker exec $TMP_MONGO mongo --eval "db.stats()"; do
        >&2 echo "Mongo is starting up ... will try again momentarily"
        sleep 3
    done

    # note that this file is generated inside of the container and then moved to the
    # current working directory.
    docker exec $TMP_MONGO bash -c "mkdir -p /data/db/dump-${DATE} && cd /data/db/dump-${DATE} && mongodump"
    mv /data/circle/mongo/dump-${DATE}/dump $(pwd)/$MONGO_BU
    rm -rf $MONGO_BU/admin
}

##
# Basic santiy check / smoke test to ensure that the mongo export performed by
# the export_mongo function contains what we expect it to contain.
##
function check_mongo() {
    echo ... verifying mongo export files
    CHECK=$(ls -al $MONGO_BU | grep circle_ghe)
    if [ -z "$CHECK" ]
    then
        echo "[FATAL] Something is wrong with the mongo export, please contact CircleCI support at enterprise-support@circleci.com for further assistance."
        exit 1
    fi
}

##
# Persist non-exportable data
# Vault
# CircleCI encryption & signing keys
##
function archive_data() {
    echo ... copying over application data

    mkdir -p $KEY_BU $VAULT_BU file

    cp /data/circle/circleci-encryption-keys/* $KEY_BU
    rsync -azv /data/circle/contexts-vault/ file/

    tar cfz vault-backup.tar.gz file/
    mv vault-backup.tar.gz $VAULT_BU

    rm -rf file
}

##
# Create tar ball with the postgreSQL and Mongo exports
##
function compress() {
    echo ... compressing exported files

    mkdir -p circleci_export

    mv $PG_BU $MONGO_BU $KEY_BU $VAULT_BU circleci_export
    rm -f circleci_export.tar.gz
    tar cfz circleci_export.tar.gz circleci_export

    rm -rf circleci_export
}

##
# Main function
##
function circleci_database_export() {
    echo "Starting CircleCI Database Export"

    preflight_checks

    start_mongo
    export_mongo
    check_mongo
    stop_mongo

    start_postgres
    export_postgres
    check_postgres
    stop_postgres

    archive_data

    compress


    echo "CircleCI Server Export Complete."
    echo "Your exported files can be found at $(pwd)/circleci_export.tar.gz"
}

circleci_database_export