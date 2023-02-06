#!/bin/bash
set -e

logFile="kots-exporter-script-$(date +%Y-%h-%d-%H%M%S).log"
kotsCleanupLogFile="kots-cleanup-$(date +%Y-%h-%d-%H%M%S).log"

help_init_options() {
    echo ""
    # Help message for Init menu
    echo "Usage:"
    echo "    ./exporter.sh [arguments]"
    echo ""
    echo "Arguments:"
    echo "  -n|--namespace          (Required) k8s namespace where kots admin is installed"
    echo "                           Defaults to 'circleci-server'"
    echo "  -l|--license            (Required) License Key String"
    echo "  -h|--help                Print help text"

    echo ""
    echo "Example :-"
    echo "# Run kots-exporter with namespace"
    echo "./exporter.sh -n <k8s-namespace>"
    echo ""
    echo "# Run execute_flyway_migration (database migration)"
    echo "./kots-exporter.sh -n <k8s-namespace> -f flyway"
    echo ""
    echo "# Run kots annotation/label cleanup function only"
    echo "./kots-exporter.sh -n <k8s-namespace> -f cleanup_kots"
    echo ""
    echo "# To display output message again"
    echo "./kots-exporter.sh -n <k8s-namespace> -f message"
}

check_prereq(){
    echo ""
    # check if kubectl is installed
    if ! command -v kubectl version &> /dev/null
    then
        error_exit "kubectl could not be found."
    fi

    # check helm is installed
    if ! command -v helm version &> /dev/null
    then
        error_exit "helm could not be found."
    fi

    # check yq is installed
    if ! command -v yq -V &> /dev/null
    then
        error_exit "yq could not be found."
    fi

    # check jq is installed
    if ! command -v jq -V &> /dev/null
    then
        error_exit "jq could not be found."
    fi
}

create_folders(){
    echo ""
    echo "############ CREATING FOLDERS ################"

    # Creating
    rm -rf  "$path/output" 2> /dev/null
    mkdir -p "$path/output" && echo "output folder has been created."
}

execute_flyway_migration(){
    echo ""
    echo "############ RUNNING FLYWAY DB MIGRATION JOB ################"

    echo "Checking if job/circle-migrator already ran -"
    if kubectl get job/circle-migrator -n $namespace -o name > /dev/null 2>&1
    then
        echo "Job circle-migrator has already been run, If you want to run again, delete the job circle-migrator via below command"
        echo "kubectl delete job/circle-migrator -n $namespace"
        echo "To Rerun: ./kots-exporter.sh -a $slug -n $namespace -f flyway"
        error_exit
    fi

    FRONTEND_POD=$(kubectl -n "$namespace" get pod -l app=frontend -o name | tail -1)
    export FRONTEND_POD

    echo "Fetching values from $FRONTEND_POD pod"
    # shellcheck disable=SC2046
    export $(kubectl -n "$namespace" exec "$FRONTEND_POD" -c frontend -- printenv | grep -Ew 'POSTGRES_USERNAME|POSTGRES_PORT|POSTGRES_PASSWORD|POSTGRES_HOST' | xargs )

    echo "Creating job/circle-migrator -"
    ( envsubst < "$path"/templates/circle-migrator.yaml | kubectl -n "$namespace" apply -f - ) \
    || error_exit "Job circle-migrator creation error"

    echo "Waiting job/circle-migrator to complete -"
    if (kubectl wait job/circle-migrator --namespace "$namespace" --for condition="complete" --timeout=600s); then
        echo "++++ DB Migration job is successful."
        echo "Fetching pod logs -"
        kubectl  -n "$namespace" logs "$(kubectl -n $namespace get pods -l app=circle-migrator -o name)" > "$path"/logs/circle-migrator.log
        echo "Pod log is available at $path/logs/circle-migrator.log"
        echo "Removing job/circle-migrator -"
        kubectl delete job/circle-migrator --namespace "$namespace"
    else
        echo "Status wait timeout for job/circle-migrator, Check the Log via - kubectl logs pods -l app=circle-migrator"
        echo "Job circle-migrator will delete automatically after 24 hours once complete."
    fi
}

export_postgres() {
    PG_POD=$(kubectl -n "$NAMESPACE" get pods | grep postgresql | tail -1 | awk '{print $1}')
    PG_PASSWORD=$(kubectl -n "$NAMESPACE" get secrets postgresql -o jsonpath="{.data.postgresql-password}" | base64 --decode)
    kubectl -n "$namepsace" exec -it "$PG_POD" -- bash -c "export PGPASSWORD='$PG_PASSWORD' && pg_dumpall -U postgres -c" > circle.sql
}

##
# Basic sanity check / smoke test to ensure that the postgresql export performed by
# the export_postgres function contains what we expect it to contain
##
check_postgres() {
    echo "... verifying postgres export file"
    if [ -z "$(grep build_jobs circle.sql | head -n1)" ]
    then
        echo "[FATAL] Something is wrong with the postgresql export file for 'conductor_production' database, please contact CircleCI support at enterprise-support@circleci.com for further assistance."
        exit 1
    fi
    if [ -z "$(grep contexts circle.sql | head -n1)" ]
    then
        echo "[FATAL] Something is wrong with the postgresql export file for 'contexts_service_production' database, please contact CircleCI support at enterprise-support@circleci.com for further assistance."
        exit 1
    fi
    if [ -z "$(grep qrtz_blob_triggers circle.sql | head -n1)" ]
    then
        echo "[FATAL] Something is wrong with the postgresql export file for 'cron_service_production' database, please contact CircleCI support at enterprise-support@circleci.com for further assistance."
        exit 1
    fi
    if [ -z "$(grep tasks circle.sql | head -n1)" ]
    then
        echo "[WARN] 'vms' database was not correctly exported."
    fi
}

export_mongo() {
    MONGO_POD="mongodb-0"
    MONGODB_USERNAME="root"
    MONGODB_PASSWORD=$(kubectl -n "$namespace" get secrets mongodb -o jsonpath="{.data.mongodb-root-password}" | base64 --decode)
    TEMP_DIR="/bitnami/circle-mongo"
    kubectl -n "$namespace" exec -it "$MONGO_POD" -- bash -c "mkdir $TEMP_DIR"
    kubectl -n "$namespace" exec -it "$MONGO_POD" -- bash -c "mongodump -u '$MONGODB_USERNAME' -p '$MONGODB_PASSWORD' --authenticationDatabase admin --db=circle_ghe --out=$TEMP_DIR"
    kubectl -n "$namespace" cp $MONGO_POD:$TEMP_DIR ${BACKUP_DIR}/circle-mongo
}

export_vault() {
    echo "Exporting Vault data"
    VAULT_POD="vault-0"
    kubectl -n "$namespace" cp -c vault "$VAULT_POD":file ${BACKUP_DIR}/file
    tar cfz ${BACKUP_DIR}/vault-backup.tar.gz ${BACKUP_DIR}/file/
    rm -rf ${BACKUP_DIR}/file
}

output_message(){
    echo ""
    echo "NOTE: After server 3.x to 4.x migration, You must rerun the Nomad terraform with modified value of 'server_endpoint' variable"
}

error_exit(){
  msg="$*"

  if [ -n "$msg" ] || [ "$msg" != "" ]; then
    echo "------->> Error: $msg"
  fi

  kill $$
}

log_setup() {
    path="$(cd "$(dirname "$0")" && pwd)"
    mkdir -p "$path/logs"

    exec > >(tee -a "$path/logs/$logFile") 2>&1

    echo "Script Path: $path"
}

############ MAIN ############

log_setup

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            namespace="$2";
            shift ;;
        -h|--help)
            help_init_options;
            exit 0 ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

check_prereq
create_folders
execute_flyway_migration
export_postgres
check_postgres
export_mongo
output_message