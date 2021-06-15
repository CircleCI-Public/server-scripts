#!/bin/bash

##
# Vault
# CircleCI encryption & signing keys
##
function archive_data() {
    echo ... copying over application data

    mkdir -p $KEY_BU $VAULT_BU file

    cp /data/circle/circleci-encryption-keys/* $KEY_BU
    rsync -azv /data/circle/contexts-vault/ file/

    tar cfz vault-backup.tar.gz file/
    mv vault-backup.tar.gz $VAULT_BU

    rm -rf file
}

##
# Create tar ball with the keys and Vault, PostgreSQL and Mongo exports
##
function compress() {
    echo ... compressing exported files

    mkdir -p circleci_export

    mv $PG_BU $MONGO_BU $KEY_BU $VAULT_BU circleci_export
    rm -f circleci_export.tar.gz
    tar cfz circleci_export.tar.gz circleci_export

    rm -rf circleci_export
}