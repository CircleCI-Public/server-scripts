#!/bin/bash

# Note: this script assumes your current kubectl context
#       includes the proper namespace to restore into.
#       `kubectl config set-context --current --namespace=$NAMESPACE`

BACKUP_DIR="circleci_export"
KEY_BU="${BACKUP_DIR}/circle-data"
VAULT_BU="${BACKUP_DIR}/circleci-vault"
MONGO_BU="${BACKUP_DIR}/circleci-mongo-export"
PG_BU="${BACKUP_DIR}/circleci-pg-export"

# Function to scale the deployments in a CCI cluster
# pass the number to scale to as the first argument
scale_deployments() {
    number=$1

    if [ -n $number ]
    then
        kubectl get deploy --no-headers -l "layer=application" | awk '{print $1}' | xargs -I echo -- kubectl scale deploy echo --replicas=$number
    else
        echo "A number of replicas must be passed as an argument to scale_deployments"
        exit 1
    fi
}

# scale down deployments to 0
scale_deployments 0
sleep 60

# Restore

## Postgres
PG_PASSWORD=$(kubectl get secrets postgresql -o jsonpath="{.data.postgresql-password}" | base64 --decode)

echo 'Restoring Postgres...'
sleep 5
cat $PG_BU/circle.sql | kubectl exec -i $(kubectl get pods | grep postgresql | tail -1 | awk '{print $1}') -- env PGPASSWORD='' psql -U postgres

## Mongo
MONGODB_USERNAME=root
MONGODB_PASSWORD=$(kubectl get secrets mongodb -o jsonpath="{.data.mongodb-root-password}" | base64 --decode)
kubectl exec mongodb-0 -- mkdir -p /tmp/backups/
kubectl cp $MONGO_BU mongodb-0:/tmp/backups/

echo "Restoring Mongo...";
kubectl exec mongodb-0 -- mongorestore --drop -u $MONGODB_USERNAME -p $MONGODB_PASSWORD --authenticationDatabase admin /tmp/backups/mongo/$db/;
kubectl exec mongodb-0 -- rm -rf /tmp/backups

## Vault

### Seal
kubectl exec vault-0 -c vault -- vault operator seal
kubectl cp -c vault $VAULT_BU/vault-backup.tar.gz vault-0:/tmp/vault-backup.tar.gz
kubectl exec vault-0 -c vault -- rm -rf file
kubectl exec vault-0 -c vault -- tar -xvzf /tmp/vault-backup.tar.gz -C /
kubectl exec vault-0 -c vault -- rm -f /tmp/vault-backup.tar.gz

### Unseal
kubectl exec vault-0 -c vault -- sh -c 'rm -rf /vault/file/sys/expire/id/auth/token/create/* && for k in $(head -n 3 /vault/file/vault-init-out | sed "s/^.*: //g"); do vault operator unseal "$k"; done; vault login $(grep "Root" /vault/file/vault-init-out | sed "s/^.*: //g"); vault token create -period="768h" > /vault/file/client-token; grep "token " /vault/file/client-token | sed "s/^token\W*//g" > /vault/__restricted/client-token'

# scale up deployments to 1
scale_deployments 1