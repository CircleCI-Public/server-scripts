#!/bin/bash

NAMESPACE=$1

if [ -z $NAMESPACE ];
then
    echo "Usage: ./vms.sh <namespace>"
    exit 1
fi

kubectl get namespace $NAMESPACE 1>/dev/null 2>&1
if [ $? -ne 0 ];
then
    echo "Namespace ${NAMESPACE} does not exist"
    exit $?
fi

VM_SERVICE_POD=$(kubectl -n $NAMESPACE get pods | grep vm-service | tail -1 | awk '{print $1}')
EXEC="kubectl -n ${NAMESPACE} exec ${VM_SERVICE_POD} -c vm-service --"

${EXEC} curl 127.0.0.1:3000/load 2>/dev/null | jq '.[] | { "VM #": .vm_count, "Task #": .task_count, "Name": .image_name, "Remote Docker": .docker_engine, "Type": .type, "Boot Avg": .boot_average}'