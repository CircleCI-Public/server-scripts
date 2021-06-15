#!/bin/bash

##
# Preflight checks
#   make sure the namespace exists
##
function preflight_checks() {
    if [ -z $NAMESPACE ]
    then
        echo "Syntax: 3.0-restore.sh <namespace>"
        exit 1
    elif [ ! command -v kubectl >/dev/null 2>&1 ]
    then
        echo ... "'kubectl' not found"
        exit 1
    elif [ $(kubectl get namespace --no-headers | grep $NAMESPACE | wc -w) -eq 0 ]
    then
        echo "Namespace '$NAMESPACE' not found."
        exit 1
    elif [[ ! "$SKIP_DATABASE_IMPORT" = "true" && ! -s $PG_BU/circle.sql ]]
    then
        echo "Postgres data at '$PG_BU/circle.sql' not found (or is empty)"
        exit 1
    elif [[ ! "$SKIP_DATABASE_IMPORT" = "true" && $(du -sm $MONGO_BU 2>/dev/null | awk '{print $1}') -lt 2 ]] # If the size is under 2MB something went wrong
    then
        echo "Mongo data at '$MONGO_BU' not found (or is empty)"
        exit 1
    elif [[ $(du -s $VAULT_BU 2>/dev/null | awk '{print $1}') -lt 5 ]]
    then
        echo "Vault data at '$VAULT_BU' not found (or is empty)"
        exit 1
    fi
}