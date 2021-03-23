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

BACKUP_DIR="circleci_export"
KEY_BU="${BACKUP_DIR}/circle-data"
VAULT_BU="${BACKUP_DIR}/circleci-vault"
MONGO_BU="${BACKUP_DIR}/circleci-mongo-export"
PG_BU="${BACKUP_DIR}/circleci-pg-export"


##
# Preflight checks
#   make sure the namespace exists
##
function preflight_checks() {
    if [ ! command -v kubectl >/dev/null 2>&1 ]
    then
        echo ... "'kubectl' not found"
        exit 1
    fi
    elif [ -z $(kubectl get namespace | grep $NAMESPACE) ]
    then
        echo "Namespace '$NAMESPACE' not found."
        exit 1
    elif [ ! -s $PG_BU/circle.sql ]
    then
        echo "Postgres data at '$PG_BU/circle.sql' not found (or is empty)"
        exit 1
    fi
    elif [[ $(du -sm $MONGO_BU 2>/dev/null | awk '{print $1}') -lt 2 ]] # If the size is under 2MB something went wrong
    then
        echo "Mongo data at '$MONGO_BU' not found (or is empty)"
        exit 1
    fi
    elif vault
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


PG_POD=$(kubectl -n $NAMESPACE get pods | grep postgresql | tail -1 | awk '{print $1}')
MONGO_POD="mongodb-0"
VAULT_POD="vault-0"

PG_PASSWORD=$(kubectl -n $NAMESPACE get secrets postgresql -o jsonpath="{.data.postgresql-password}" | base64 --decode)
MONGODB_USERNAME="root"
MONGODB_PASSWORD=$(kubectl -n $NAMESPACE get secrets mongodb -o jsonpath="{.data.mongodb-root-password}" | base64 --decode)


function import_postgres() {
    echo '...importing Postgres...'

    # Note: This import assumes `pg_dumpall -c` was run to drop tables before ...importing into them.
    cat $PG_BU/circle.sql | kubectl -n $NAMESPACE exec -i $PG_POD -- env PGPASSWORD='' psql -U postgres
}

function import_mongo() {
    echo "...importing Mongo...";

    kubectl -n $NAMESPACE exec $MONGO_POD -- mkdir -p /tmp/backups/
    kubectl -n $NAMESPACE cp $MONGO_BU $MONGO_POD:/tmp/backups/

    kubectl -n $NAMESPACE exec $MONGO_POD -- mongorestore --drop -u $MONGODB_USERNAME -p $MONGODB_PASSWORD --authenticationDatabase admin /tmp/backups/mongo/$db/;
    kubectl -n $NAMESPACE exec $MONGO_POD -- rm -rf /tmp/backups
}

function import_vault() {
    echo "...importing Vault..."

    ### Seal
    kubectl -n $NAMESPACE exec $VAULT_POD -c vault -- vault operator seal
    kubectl -n $NAMESPACE cp -c vault $VAULT_BU/vault-backup.tar.gz $VAULT_POD:/tmp/vault-backup.tar.gz
    kubectl -n $NAMESPACE exec $VAULT_POD -c vault -- rm -rf file
    kubectl -n $NAMESPACE exec $VAULT_POD -c vault -- tar -xvzf /tmp/vault-backup.tar.gz -C /
    kubectl -n $NAMESPACE exec $VAULT_POD -c vault -- rm -f /tmp/vault-backup.tar.gz

    ### Unseal
    kubectl -n $NAMESPACE exec $VAULT_POD -c vault -- sh -c 'rm -rf /vault/file/sys/expire/id/auth/token/create/* && for k in $(head -n 3 /vault/file/vault-init-out | sed "s/^.*: //g"); do vault operator unseal "$k"; done; vault login $(grep "Root" /vault/file/vault-init-out | sed "s/^.*: //g"); vault token create -period="768h" > /vault/file/client-token; grep "token " /vault/file/client-token | sed "s/^token\W*//g" > /vault/__restricted/client-token'

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

    echo "...scaling application deployments to 1..."
    scale_deployments 1

    echo "CircleCI Server Import Complete"

    key_reminder
}

circleci_database_import