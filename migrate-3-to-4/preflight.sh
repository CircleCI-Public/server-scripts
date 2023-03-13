#!/bin/bash

##
# Preflight checks
#   make sure the namespace exists
##
function preflight_checks() {
    echo "Starting preflight checks"
    if [ -z "$NAMESPACE" ]
    then
        echo "Syntax: restore.sh <namespace>"
        exit 1
    elif [ ! "$(which kubectl)" ]
    then
        echo ... "'kubectl' not found"
        exit 1
    elif [ ! "$(which jq)" ]
    then
        echo ... "'jq' not found"
        exit 1
    elif [ "$(kubectl get namespace --no-headers "$NAMESPACE" | wc -w)" -eq 0 ]
    then
        echo "Namespace '$NAMESPACE' not found."
        exit 1
    elif [ ! -s "$PG_BU"/circle.sql ]
    then
        echo "Postgres data at '$PG_BU/circle.sql' not found (or is empty)"
        exit 1
    elif [ ! -s "$MONGO_BU" ]
    then
        echo "Mongo data at '$MONGO_BU' not found (or is empty)"
        exit 1
    elif [[ ! -s "$VAULT_BU" && $(du -s "$VAULT_BU" 2>/dev/null | awk '{print $1}') -lt 5 ]]
    then
        echo "Vault data at '$VAULT_BU' not found (or is empty)"
        exit 1
    fi
    echo "Finishing preflight checks"
}