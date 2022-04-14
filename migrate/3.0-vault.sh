#!/bin/bash

set -e

function import_vault() {
    echo "...importing Vault..."

    VAULT_POD="vault-0"
    TEST_POD="z-test-pod"
    VAULT_BU="${BACKUP_DIR}/circleci-vault"

    ### Seal
    kubectl -n "$NAMESPACE" exec "$VAULT_POD" -c vault -- vault operator seal

    # Scale down vault
    kubectl -n "$NAMESPACE" scale --replicas=0 sts/vault

    # Creating a test pod
    kubectl -n "$NAMESPACE" apply -f ./z-test-pod.yml

    # Check the content
    kubectl -n "$NAMESPACE" exec "$TEST_POD" -- ls -l /vault/file

    # Delete the PVC content
    kubectl -n "$NAMESPACE" exec "$TEST_POD" -- rm -rf /vault/file

    # Copy the vault backup into test pod
    kubectl -n "$NAMESPACE" cp -v=2 -c vault "$VAULT_BU"/vault-backup.tar.gz "$TEST_POD":/tmp/vault-backup.tar.gz

    # Extract the content
    kubectl -n "$NAMESPACE" exec "$TEST_POD" -- tar -xvzf /tmp/vault-backup.tar.gz -C /vault/

    # Check if content is extracted
    kubectl -n "$NAMESPACE" exec "$TEST_POD" -- ls -l /vault/file

    # If Yes, delete the pod now
    kubectl -n "$NAMESPACE" delete "$TEST_POD"

    # Bring up the Vault sts and wait to be up
    kubectl -n "$NAMESPACE" scale --replicas=1 sts/vaults

    ### Unseal
    kubectl -n "$NAMESPACE" exec "$VAULT_POD" -c vault -- sh -c "rm -rf /vault/file/sys/expire/id/auth/token/create/* && for k in \$(head -n 3 /vault/file/vault-init-out | sed \"s/^.*: //g\"); do vault operator unseal \"\$k\"; done; vault login \$(grep \"Root\" /vault/file/vault-init-out | sed \"s/^.*: //g\"); vault token create -period=\"768h\" > /vault/file/client-token; grep \"token \" /vault/file/client-token | sed \"s/^token\W*//g\" > /vault/__restricted/client-token"
}