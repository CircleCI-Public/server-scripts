#!/bin/bash

# Function to scale the deployments in a CCI cluster
# pass the number to scale to as the first argument
scale_deployments() {
    number=$1

    if [ -n "$number" ]
    then
        kubectl -n "$NAMESPACE" get deploy --no-headers -l "layer=application" | awk '{print $1}' | xargs -I echo -- kubectl -n "$NAMESPACE" scale deploy echo --replicas="$number"
    else
        echo "A number of replicas must be passed as an argument to scale_deployments"
        exit 1
    fi
}

scale_reminder() {
    echo "Please note all deployments have been scaled to 1."
    echo "This is not necessarily desirable in all scenarios."
    echo "Consider scaling some deployments for high availability ."
}