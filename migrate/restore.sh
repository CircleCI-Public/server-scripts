#!/bin/bash

##
# CircleCI Database Import Script
#
#   * Intended only for use with installations of CircleCI Server 3.0.
#
#   This script will import data from a CircleCI Server 2.19.x instance
#   given the tarball called `circleci_export.tar.gz` has already been
#   extracted.
#
#   Application deployments will be scaled to zero and then to one.
#   Please note a replica of 1 is not desirable for output-processor.
##

set -e

BACKUP_DIR="circleci_export"
KEY_BU="${BACKUP_DIR}/circle-data"
VAULT_BU="${BACKUP_DIR}/circleci-vault"
MONGO_BU="${BACKUP_DIR}/circleci-mongo-export"
PG_BU="${BACKUP_DIR}/circleci-pg-export"

NAMESPACE=$1

##
# Preflight checks
#   make sure the namespace exists
##
function preflight_checks() {
    if [ -z $NAMESPACE ]
    then
        echo "Syntax: restore.sh <namespace>"
        exit 1
    elif [ ! command -v kubectl >/dev/null 2>&1 ]
    then
        echo ... "'kubectl' not found"
        exit 1
    elif [ $(kubectl get namespace --no-headers | grep $NAMESPACE | wc -w) -eq 0 ]
    then
        echo "Namespace '$NAMESPACE' not found."
        exit 1
    elif [ ! -s $PG_BU/circle.sql ]
    then
        echo "Postgres data at '$PG_BU/circle.sql' not found (or is empty)"
        exit 1
    elif [[ $(du -sm $MONGO_BU 2>/dev/null | awk '{print $1}') -lt 2 ]] # If the size is under 2MB something went wrong
    then
        echo "Mongo data at '$MONGO_BU' not found (or is empty)"
        exit 1
    elif [[ $(du -s $VAULT_BU 2>/dev/null | awk '{print $1}') -lt 5 ]]
    then
        echo "Vault data at '$VAULT_BU' not found (or is empty)"
        exit 1
    fi
}

# Function to scale the deployments in a CCI cluster
# pass the number to scale to as the first argument
scale_deployments() {
    number=$1

    if [ -n $number ]
    then
        kubectl -n $NAMESPACE get deploy --no-headers -l "layer=application" | awk '{print $1}' | xargs -I echo -- kubectl -n $NAMESPACE scale deploy echo --replicas=$number
    else
        echo "A number of replicas must be passed as an argument to scale_deployments"
        exit 1
    fi
}

function import_postgres() {
    echo '...importing Postgres...'

    PG_POD=$(kubectl -n $NAMESPACE get pods | grep postgresql | tail -1 | awk '{print $1}')
    PG_PASSWORD=$(kubectl -n $NAMESPACE get secrets postgresql -o jsonpath="{.data.postgresql-password}" | base64 --decode)

    # Note: This import assumes `pg_dumpall -c` was run to drop tables before ...importing into them.
    cat $PG_BU/circle.sql | kubectl -n $NAMESPACE exec -i $PG_POD -- env PGPASSWORD=$PG_PASSWORD psql -U postgres
}

function import_mongo() {
    echo "...importing Mongo...";

    MONGO_POD="mongodb-0"
    MONGODB_USERNAME="root"
    MONGODB_PASSWORD=$(kubectl -n $NAMESPACE get secrets mongodb -o jsonpath="{.data.mongodb-root-password}" | base64 --decode)

    kubectl -n $NAMESPACE exec $MONGO_POD -- mkdir -p /tmp/backups/
    kubectl -n $NAMESPACE cp -v=2 $MONGO_BU $MONGO_POD:/tmp/backups/

    kubectl -n $NAMESPACE exec $MONGO_POD -- mongorestore --drop -u $MONGODB_USERNAME -p $MONGODB_PASSWORD --authenticationDatabase admin /tmp/backups/circleci-mongo-export/;
    kubectl -n $NAMESPACE exec $MONGO_POD -- rm -rf /tmp/backups
}

function import_vault() {
    echo "...importing Vault..."

    VAULT_POD="vault-0"

    ### Seal
    kubectl -n $NAMESPACE exec $VAULT_POD -c vault -- vault operator seal
    kubectl -n $NAMESPACE cp -v=2 -c vault $VAULT_BU/vault-backup.tar.gz $VAULT_POD:/tmp/vault-backup.tar.gz
    kubectl -n $NAMESPACE exec $VAULT_POD -c vault -- rm -rf /vault/file/*
    kubectl -n $NAMESPACE exec $VAULT_POD -c vault -- tar -xvzf /tmp/vault-backup.tar.gz -C /vault/
    kubectl -n $NAMESPACE exec $VAULT_POD -c vault -- rm -f /tmp/vault-backup.tar.gz

    ### Unseal
    kubectl -n $NAMESPACE exec $VAULT_POD -c vault -- sh -c 'rm -rf /vault/file/sys/expire/id/auth/token/create/* && for k in $(head -n 3 /vault/file/vault-init-out | sed "s/^.*: //g"); do vault operator unseal "$k"; done; vault login $(grep "Root" /vault/file/vault-init-out | sed "s/^.*: //g"); vault token create -period="768h" > /vault/file/client-token; grep "token " /vault/file/client-token | sed "s/^token\W*//g" > /vault/__restricted/client-token'
}

function reinject_bottoken() {
    JOB_NAME=$(kubectl -n $NAMESPACE get jobs -o json | jq '.items[0].metadata.name' -r)
    echo "found job $JOB_NAME"
    ### Re-run the job, but also remove some auto generated fields that cannot be re-applied
    kubectl -n $NAMESPACE get job $JOB_NAME -o json | jq 'del(.spec.template.metadata.labels)' | jq 'del(.spec.selector)' | kubectl replace --force -f -
}

function key_reminder() {
    echo ""
    echo "###################################"
    echo "##   Encryption & Signing keys   ##"
    echo "##   must be uploaded to kots.   ##"
    echo "###################################"
    echo ""
    echo "You may find your keys here:  $(pwd)/${KEY_BU}"

    ls -lh $KEY_BU | grep -v ^total
}

function circleci_database_import() {
    echo "Starting CircleCI Database Import"

    preflight_checks

    echo "...scaling application deployments to 0..."
    scale_deployments 0

    # wait one minute for pods to scale down
    sleep 60

    import_postgres
    import_mongo
    import_vault

    reinject_bottoken

    echo "...scaling application deployments to 1..."
    scale_deployments 1

    echo "CircleCI Server Import Complete"

    key_reminder
}

circleci_database_import
