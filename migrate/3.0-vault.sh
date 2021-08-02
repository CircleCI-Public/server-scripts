#!/bin/bash

set -e

function import_vault() {
    echo "...importing Vault..."

    VAULT_POD="vault-0"
    VAULT_BU="${BACKUP_DIR}/circleci-vault"

    ### Seal
    kubectl -n "$NAMESPACE" exec "$VAULT_POD" -c vault -- vault operator seal
    kubectl -n "$NAMESPACE" cp -v=2 -c vault "$VAULT_BU"/vault-backup.tar.gz "$VAULT_POD":/tmp/vault-backup.tar.gz
    kubectl -n "$NAMESPACE" exec "$VAULT_POD" -c vault -- rm -rf /vault/file/*
    kubectl -n "$NAMESPACE" exec "$VAULT_POD" -c vault -- tar -xvzf /tmp/vault-backup.tar.gz -C /vault/
    kubectl -n "$NAMESPACE" exec "$VAULT_POD" -c vault -- rm -f /tmp/vault-backup.tar.gz

    ### Unseal
    kubectl -n "$NAMESPACE" exec "$VAULT_POD" -c vault -- sh -c "rm -rf /vault/file/sys/expire/id/auth/token/create/* && for k in \$(head -n 3 /vault/file/vault-init-out | sed \"s/^.*: //g\"); do vault operator unseal \"\$k\"; done; vault login \$(grep \"Root\" /vault/file/vault-init-out | sed \"s/^.*: //g\"); vault token create -period=\"768h\" > /vault/file/client-token; grep \"token \" /vault/file/client-token | sed \"s/^token\W*//g\" > /vault/__restricted/client-token"
}