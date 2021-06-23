#!/bin/bash

function reinject_bottoken() {
    JOB_NAME=$(kubectl -n $NAMESPACE get jobs -o json | jq '.items[0].metadata.name' -r)
    echo "found job $JOB_NAME"
    ### Re-run the job, but also remove some auto generated fields that cannot be re-applied
    kubectl -n $NAMESPACE get job $JOB_NAME -o json | jq 'del(.spec.template.metadata.labels)' | jq 'del(.spec.selector)' | kubectl replace --force -f -
}