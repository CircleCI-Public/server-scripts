#!/bin/bash

function reinject_bottoken() {
    JOB_NAME=$(kubectl -n "$NAMESPACE" get jobs -o json | jq '.items[0].metadata.name' -r)
    echo "Found job $JOB_NAME"
    kubectl -n "$NAMESPACE" get job "${JOB_NAME}" -o json | jq 'del(.spec.template.metadata.labels."controller-uid") | del(.spec.selector)' > bottokenjob.json
    kubectl -n "$NAMESPACE" replace --force -f bottokenjob.json
}
