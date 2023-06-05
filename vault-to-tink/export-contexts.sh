#!/usr/bin/env bash

# NOTES:
# This script will assume:
# * lein dependencies are pre-cached OR the internet is accessible
# * we have modified the kubectl context to be in the correct namespace (kubectl config set-context --current --namespace <namespace>)
# * Docker is running & can be utilized without sudo
# * the Postgres server is internal to the CircleCI installation

SVC_NAME=contexts-service
SVC_PORT=6005

printf '' >contexts.json

INET_ADDR="$(ip -4 route get 192.0.2.1 | grep -o 'src [0-9.]\{1,\}' | awk '{ print $2 }')"
if [ -z "$INET_ADDR" ]; then
  echo "Unable to determine IP address"
  exit 1
fi

kubectl port-forward "$(kubectl get po -l app="${SVC_NAME}" -o jsonpath='{.items[0].metadata.name}')" --address "${INET_ADDR}" "${SVC_PORT}" 1>/dev/null 2>&1 &
PORT_FORWARD_SUCCESS=$?

if [ "${PORT_FORWARD_SUCCESS}" -ne 0 ]; then
  echo "Unable to port-forward to ${SVC_NAME}"
  exit 1
fi

CONTEXTS=$(kubectl exec -it postgresql-0 -- bash -c "PGPASSWORD=\$POSTGRES_PASSWORD PAGER= psql -t -U postgres -d contexts_service_production -c \"SELECT DISTINCT(owning_grouping_ref) FROM contexts\";" | grep -e -)

echo "Contexts Table"
echo "----------------------------------------------------------------------------"
echo "$CONTEXTS"
echo "----------------------------------------------------------------------------"
echo ""

for CONTEXT in $CONTEXTS; do
  GROUPING_ID=$(echo "$CONTEXT" | tr -d '[:space:]')
  echo "Processing context grouping id $GROUPING_ID"

  CLOJURE=$(printf "(doseq [obj (contexts-service.db/get-contexts \"%s\")]
                        (let [org-ref (:contexts-service-client.context.response/organization-ref obj)
                              context-id (:contexts-service-client.context.response/id obj)
                              resources (:contexts-service-client.context.response/resources obj)
                              keyvals (map (fn [res] {:name (:contexts-service-client.context/variable res)
                                                    :value (:contexts-service-client.context/value res)})
                                          resources)]
                          (println (cheshire.core/generate-string {
                                    :organization-ref org-ref
                                    :context-id context-id
                                    :contexts keyvals}))))" "${GROUPING_ID}")

  docker run --rm -it clojure \
    bash -c "lein repl :connect \"${INET_ADDR}\":6005 <<< '$CLOJURE'" |
    grep '{"organization-ref' \
      >>contexts.json
done
