#!/bin/bash

##
# Start temporary Mongo container with mounted data volume
##
function start_mongo() {
    echo ... starting new mongo container with existing volume
    docker run --rm --name "$TMP_MONGO" -d -v "$MONGO_DATA":/data/db mongo:"$MONGO_VERSION"
}

##
# Stop the Mongo container tht we created with the start_mongo function
##
function stop_mongo() {
    echo ... stopping mongo container
    docker rm -f "$TMP_MONGO"
}

##
# Export Mongo database once the container has started and is accepting connections
##
function export_mongo() {
    echo ... exporting mongo database

    until docker exec "${TMP_MONGO}" mongo --eval "db.stats()"; do
        >&2 echo "Mongo is starting up ... will try again momentarily"
        sleep 3
    done

    # note that this file is generated inside of the container and then moved to the
    # current working directory.
    docker exec "${TMP_MONGO}" bash -c "mkdir -p /data/db/dump-${DATE} && cd /data/db/dump-${DATE} && mongodump"
    mv "/data/circle/mongo/dump-${DATE}/dump" "$(pwd)/${MONGO_BU}"
    rm -rf "$MONGO_BU"/admin
}

##
# Basic santiy check / smoke test to ensure that the mongo export performed by
# the export_mongo function contains what we expect it to contain.
##
function check_mongo() {
    echo ... verifying mongo export files
    CHECK=$(ls -al "$MONGO_BU"/circle_ghe)
    if [ -z "$CHECK" ]
    then
        echo "[FATAL] Something is wrong with the mongo export, please contact CircleCI support at enterprise-support@circleci.com for further assistance."
        exit 1
    fi
}