#!/bin/bash

set -e

function import_vault() {
    echo "Importing Vault"

    VAULT_STS="vault"
    VAULT_POD="vault-0"
    VAULT_PVC="data-vault-0"
    TEMP_VAULT_POD="temp-vault"
    TEMP_VAULT_POD_YAML="temp-vault-pod.yml"
    VAULT_PVC_YAML="vault-pvc.yml"

    # Scaling down Vault
    kubectl -n "$NAMESPACE" scale --replicas=0 sts/$VAULT_STS

    # Waiting for Vault termination
    while [[ $(kubectl -n "$NAMESPACE" get pods -l app="$VAULT_STS" 2>/dev/null | grep -c "$VAULT_STS") -gt 0 ]]
    do
        echo "Vault is terminating"
        sleep 15
    done

    # Deleting the PVC
    kubectl -n "$NAMESPACE" delete pvc/$VAULT_PVC

    # Recreating the PVC
    kubectl -n "$NAMESPACE" apply -f "$VAULT_PVC_YAML"

    # Creating a test pod
    kubectl -n "$NAMESPACE" apply -f "$TEMP_VAULT_POD_YAML"

    # Waiting for Pod temp-vault
    while [[ ! $(kubectl -n "$NAMESPACE" get pods -l app="$TEMP_VAULT_POD" 2>/dev/null | grep -c "1/1") -gt 0 ]]
    do
        echo "Waiting for $TEMP_VAULT_POD to scale up"
        sleep 15
    done

    # Copy the vault backup into test pod
    kubectl -n "$NAMESPACE" cp -v=2 "$VAULT_BU"/vault-backup.tar.gz "$TEMP_VAULT_POD":/tmp/vault-backup.tar.gz

    # Extract the content
    kubectl -n "$NAMESPACE" exec "$TEMP_VAULT_POD" -- tar -xvzf /tmp/vault-backup.tar.gz -C /tmp/vault/
    kubectl -n "$NAMESPACE" exec "$TEMP_VAULT_POD" -- cp -r /tmp/vault/circleci_export/file /tmp/vault

    # Check if content is extracted
    kubectl -n "$NAMESPACE" exec "$TEMP_VAULT_POD" -- ls -al /tmp/vault/ /tmp/vault/file

    # If Yes, delete the pod now
    kubectl -n "$NAMESPACE" delete pod/"$TEMP_VAULT_POD"

    # Bring up the Vault sts and wait to be up
    kubectl -n "$NAMESPACE" scale --replicas=1 sts/$VAULT_STS

    # Waiting for Pod vault
    while [[ ! $(kubectl -n "$NAMESPACE" get pods -l app="$VAULT_STS" 2>/dev/null | grep -c "2/2") -gt 0 ]]
    do
        echo "Waiting for $VAULT_STS to scale up"
        sleep 15
    done

    kubectl -n "$NAMESPACE" get pods -l app="$VAULT_STS"

    ### Unseal
    kubectl -n "$NAMESPACE" exec "$VAULT_POD" -c vault -- sh -c "rm -rf /vault/file/sys/expire/id/auth/token/create/* && for k in \$(head -n 3 /vault/file/vault-init-out | sed \"s/^.*: //g\"); do vault operator unseal \"\$k\"; done; vault login \$(grep \"Root\" /vault/file/vault-init-out | sed \"s/^.*: //g\"); vault token create -period=\"768h\" > /vault/file/client-token; grep \"token \" /vault/file/client-token | sed \"s/^token\W*//g\" > /vault/__restricted/client-token"
}
