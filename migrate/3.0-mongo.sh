#!/bin/bash

function import_mongo() {
    echo "...importing Mongo...";

    MONGO_POD="mongodb-0"
    MONGODB_USERNAME="root"
    MONGODB_PASSWORD=$(kubectl -n "$NAMESPACE" get secrets mongodb -o jsonpath="{.data.mongodb-root-password}" | base64 --decode)

    kubectl -n "$NAMESPACE" exec "$MONGO_POD" -- mkdir -p /tmp/backups/
    kubectl -n "$NAMESPACE" cp -v=2 "$MONGO_BU" "$MONGO_POD":/tmp/backups/

    kubectl -n "$NAMESPACE" exec "$MONGO_POD" -- mongorestore --drop -u "$MONGODB_USERNAME" -p "$MONGODB_PASSWORD" --authenticationDatabase admin /tmp/backups/circleci-mongo-export/;
    kubectl -n "$NAMESPACE" exec "$MONGO_POD" -- rm -rf /tmp/backups
}