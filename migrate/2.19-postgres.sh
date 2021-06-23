#!/bin/bash

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
