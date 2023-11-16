#!/bin/bash

DIR=$(dirname $0)
NAMESPACE=$1

if [ -z $NAMESPACE ];
then
    echo "Usage: ./fleet-state.sh <namespace>"
    exit 1
fi

kubectl get namespace $NAMESPACE 1>/dev/null 2>&1
if [ $? -ne 0 ];
then
    echo "Namespace ${NAMESPACE} does not exist"
    exit $?
fi

#${DIR}/nomad/nomad.sh $NAMESPACE
${DIR}/distributor/distributor.sh $NAMESPACE