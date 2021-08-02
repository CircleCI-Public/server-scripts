#!/bin/bash

function reinject_bottoken() {
    JOB_NAME=$(kubectl -n "$NAMESPACE" get jobs -o json | jq '.items[0].metadata.name' -r)
    echo "Found job $JOB_NAME"
    ### Delete the job. A fresh deploy will happen when the signing/encryption keys are uploaded, creating a new job.
    kubectl -n "$NAMESPACE" delete job "$JOB_NAME"
}