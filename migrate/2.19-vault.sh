#!/bin/bash

##
# Vault export
##
function export_vault() {
    echo ... exporting Vault data

    mkdir -p "$VAULT_BU" file

    rsync -azv /data/circle/contexts-vault/ file/

    tar cfz vault-backup.tar.gz file/
    mv vault-backup.tar.gz "$VAULT_BU"

    rm -rf file
}
