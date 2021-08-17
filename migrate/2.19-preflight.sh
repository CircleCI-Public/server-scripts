#!/bin/bash

##
# Preflight checks
#   make sure script is running as root
#   make sure circle, mongo, and postgres are shut down
##
function preflight_checks() {

    if [ "$(id -u)" -ne 0 ]
    then
        echo "Please run this script as root"
        exit 1

    elif [[ ! "$SKIP_MONGO $SKIP_POSTGRES $SKIP_VAULT" = "true true true" && -n "$(docker ps | grep circleci-frontend | head -n1 )" ]]
    then
        echo "Please shut down CircleCI from the replicated console at https://<YOUR_CIRCLE_URL>:8800 before running this script."
        exit 1

    elif [[ ! "$SKIP_MONGO" = "true" && -n "$(docker ps | grep mongo | head -n1 )" ]]
    then
        echo "Please shut down any other Mongo containers before running this script"
        exit 1

    elif [[ ! "$SKIP_POSTGRES" = "true" && -n "$(docker ps | grep -v replicated | grep postgres | head -n1 )" ]]
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