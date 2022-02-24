#!/bin/bash

NAMESPACE=$1
DISTRIBUTE_POD=$(kubectl -n $NAMESPACE get pods | grep distributor-dispatcher | tail -1 | awk '{print $1}')
EXEC="kubectl -n ${NAMESPACE} exec ${DISTRIBUTE_POD} -c distributor --"

${EXEC} apk add curl
${EXEC} curl 127.0.0.1:7623/tasks?executor=machine,mac,windows | jq '.[] | { "Count": .count, "Type": .resource_class.executor, "Size": .resource_class.class, "Image": .resource_class.image } '