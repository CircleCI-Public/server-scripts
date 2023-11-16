#!/bin/bash

NAMESPACE=$1
FRONTEND_POD=$(kubectl -n ${NAMESPACE} get pod -lapp=frontend -o name)
EXEC="kubectl -n ${NAMESPACE} exec ${FRONTEND_POD} -c frontend --"

echo ""
echo "Fetching Job Counts - "
${EXEC} curl -s http://distributor-internal:80/tasks?executor=machine,mac,windows,linux,arm,android | jq #'.[] | { "Count": .count, "Type": .resource_class.executor, "Size": .resource_class.class, "Image": .resource_class.image } '