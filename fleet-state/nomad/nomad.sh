#!/bin/bash

DIR=$(dirname $0)
NAMESPACE=$1

if [ -z $NAMESPACE ];
then
    echo "Usage: ./nomad.sh <namespace>"
    exit 1
fi

kubectl get namespace $NAMESPACE 1>/dev/null 2>&1
if [ $? -ne 0 ];
then
    echo "Namespace ${NAMESPACE} does not exist"
    exit $?
fi


NOMAD_POD=$(kubectl -n ${NAMESPACE} get pods | grep nomad-server | tail -1 | awk '{print $1}')
EXEC="kubectl -n ${NAMESPACE} exec ${NOMAD_POD} --"

${EXEC} nomad node status -json | \
    sed -e '1 s|.*|[|' -e '$ s|.*|]|' | \
    jq '.[] .ID' | \
    xargs -n1 ${EXEC} nomad node status | \
    grep -e "/dev/" -e "Name" | \
    awk -f ${DIR}/script.awk