#!/bin/bash

set -e

function import_vault() {
    echo "...importing Vault..."

    VAULT_POD="vault-0"
    VAULT_PVC="data-vault-0"
    TEST_POD="ztest"
    TEST_POD_YAML="$DIR/ztest-pod.yml"
    VAULT_PVC_YAML="$DIR/vault-pvc.yml"
    VAULT_BU="${BACKUP_DIR}/circleci-vault"

    ## Seal
    kubectl -n "$NAMESPACE" exec "$VAULT_POD" -c vault -- vault operator seal

    # Scaling down Vault
    kubectl -n "$NAMESPACE" scale --replicas=0 sts/vault

    # Waiting for Vault termination
    while [[ $(kubectl -n "$NAMESPACE" get pods -l app=vault 2>/dev/null | grep -c vault) -gt 0 ]]
    do
        echo "Vault is terminating"
        sleep 15
    done

    # Fetching the PVC info
    VOL_SIZE=$(kubectl -n "$NAMESPACE" get pvc/$VAULT_PVC -o=jsonpath="{.status.capacity.storage}")
    echo "Volume size of $VAULT_PVC is - $VOL_SIZE"

    # Deleting the PVC
    kubectl -n "$NAMESPACE" delete pvc/$VAULT_PVC

    # Recreating the PVC
    sed  "s/VOLUME_SIZE/$VOL_SIZE/" < "$VAULT_PVC_YAML" | kubectl -n "$NAMESPACE" apply -f -
    kubectl -n "$NAMESPACE" get pvc/$VAULT_PVC

    # Creating a test pod
    kubectl -n "$NAMESPACE" apply -f "$TEST_POD_YAML"

    # Waiting for Pod ztest
    while [[ ! $(kubectl -n "$NAMESPACE" get pods -l app=ztest 2>/dev/null | grep -c "1/1") -gt 0 ]]
    do
        echo "Waiting for ztest to scale up"
        sleep 15
    done

    kubectl -n "$NAMESPACE" get pods -l app=ztest

    # Copy the vault backup into test pod
    kubectl -n "$NAMESPACE" cp -v=2 "$VAULT_BU"/vault-backup.tar.gz "$TEST_POD":/tmp/vault-backup.tar.gz

    # Extract the content
    kubectl -n "$NAMESPACE" exec "$TEST_POD" -- tar -xvzf /tmp/vault-backup.tar.gz -C /tmp/vault/

    # Check if content is extracted
    kubectl -n "$NAMESPACE" exec "$TEST_POD" -- ls -l /tmp/vault/ /tmp/vault/file

    # If Yes, delete the pod now
    kubectl -n "$NAMESPACE" delete pod/"$TEST_POD"  

    # Bring up the Vault sts and wait to be up
    kubectl -n "$NAMESPACE" scale --replicas=1 sts/vault

    # Waiting for Pod vault
    while [[ ! $(kubectl -n "$NAMESPACE" get pods -l app=vault 2>/dev/null | grep -c "2/2") -gt 0 ]]
    do
        echo "Waiting for Vault to scale up"
        sleep 15
    done 

    kubectl -n "$NAMESPACE" get pods -l app=vault

    ### Unseal
    kubectl -n "$NAMESPACE" exec "$VAULT_POD" -c vault -- sh -c "rm -rf /vault/file/sys/expire/id/auth/token/create/* && for k in \$(head -n 3 /vault/file/vault-init-out | sed \"s/^.*: //g\"); do vault operator unseal \"\$k\"; done; vault login \$(grep \"Root\" /vault/file/vault-init-out | sed \"s/^.*: //g\"); vault token create -period=\"768h\" > /vault/file/client-token; grep \"token \" /vault/file/client-token | sed \"s/^token\W*//g\" > /vault/__restricted/client-token"
}