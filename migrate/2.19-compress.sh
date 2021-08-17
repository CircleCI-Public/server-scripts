#!/bin/bash

##
# Create tar ball with the signing & encryption keys,
# Vault, PostgreSQL and Mongo exports.
##
function compress() {
    echo ... compressing exported files

    mkdir -p circleci_export

    mv "$PG_BU" "$MONGO_BU" "$KEY_BU" "$VAULT_BU" circleci_export
    rm -f circleci_export.tar.gz
    tar cfz circleci_export.tar.gz circleci_export

    rm -rf circleci_export
}