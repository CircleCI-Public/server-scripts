#!/bin/bash
set -e

# global list to track resource types to annotate
resourceList=("sa" "cm" "jobs" "ds" "secret" "role" "RoleBinding" "svc" "cj" "deploy" "sts" "netpol" "pvc")
logFile="kots-exporter-script-$(date +%Y-%h-%d-%H%M%S).log"
annotateLogFile="helm-annotation-$(date +%Y-%h-%d-%H%M%S).log"
kotsCleanupLogFile="kots-cleanup-$(date +%Y-%h-%d-%H%M%S).log"

help_init_options() {
    echo ""
    # Help message for Init menu
    echo "Usage:"
    echo "    ./kots-exporter.sh [arguments]"
    echo ""
    echo "Arguments:"
    echo "  -a|--release-name       (Required) release name of your CircleCI server install"
    echo "                           Defaults to 'circleci-server'"
    echo "  -n|--namespace          (Required) k8s namespace where kots admin is installed"
    echo "                           Defaults to 'circleci-server'"
    echo "  -r|--annotate           (Optional) Annotate k8s resources if set to 1"
    echo "                           Defaults to 1"
    echo "  -f|--func               (Optional) Run a one-off custom function"
    echo "                           Accepted values: \"annotate\",\"flyway\",\"cleanup_kots\" and \"message\""
    echo "  -l|--license            (Required) License Key String"
    echo "  -h|--help                Print help text"

    echo ""
    echo "Example :-"
    echo "# Run kots-exporter with release-name and namespace"
    echo "./kots-exporter.sh -a <release-name> -n <k8s-namespace> -l <license>"
    echo ""
    echo "# Run execute_flyway_migration (database migration)"
    echo "./kots-exporter.sh -a <release-name> -n <k8s-namespace> -f flyway"
    echo ""
    echo "# Run helm annotation function only"
    echo "./kots-exporter.sh -a <release-name> -n <k8s-namespace> -f annotate"
    echo ""
    echo "# Run kots annotation/label cleanup function only"
    echo "./kots-exporter.sh -a <release-name> -n <k8s-namespace> -f cleanup_kots"
    echo ""
    echo "# To display output message again"
    echo "./kots-exporter.sh -a <release-name> -n <k8s-namespace> -f message"
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

    # check if secret/regcred exists
    if ! kubectl get secret/regcred -n "$namespace" -o name > /dev/null 2>&1
    then
        error_exit "Secret regcred does not exist in k8s namespace - $namespace"
    fi
}

check_required_args(){
    echo ""
    echo "############ CHECKING RQUIRED ARGUEMENTS ################"

    # check for required arguments
    if [[ -z $slug || -z $namespace ]];
    then
        echo "We need some information before we can begin:"
    fi

    if [ -z "$slug" ];
    then
        read -r -p 'Release name (circleci-server): ' slug
    fi

    if [ -z "$namespace" ];
    then
        read -r -p 'KOTS admin namespace (circleci-server): ' namespace
    fi

    if [[ -z "$license" ]]  &&  [[ -z "$func" ]];
    then
        read -r -p 'License Key String: ' license
    fi
}

set_default_value(){
    echo ""
    echo "############ SET DEFAULT VALUES ################"

    # set defaults
    if [ -z "$slug" ];
    then
        slug="circleci-server"
    fi

    if [ -z "$namespace" ];
    then
        namespace="circleci-server"
    fi

    if [ -z "$annotate" ];
    then
        annotate=1
    fi

    if [ -z "$func" ];
    then
        func="all"
    fi
}

create_folders(){
    echo ""
    echo "############ CREATING FOLDERS ################"

    # Creating
    rm -rf  "$path/output" 2> /dev/null
    mkdir -p "$path/output" && echo "output folder is created."
}

download_helm_values(){
    echo ""
    echo "############ DOWNLOADING HELM VALUE ################"
    echo ""
    echo "Downloading helm value file from release: $slug and namespace: $namespace"
    (helm get values "$slug" -n "$namespace" --revision 1 -o yaml > "$path"/output/helm-values.yaml \
    && echo "++++ Helm value file download is completed") \
    || error_exit "Helm value file download"

}

modify_helm_values(){
    echo ""
    echo "############ MODIFY HELM VALUE ################"

    echo ""
    echo "Adding domainName"
    domainName="$(awk '/domainName/ {print $2;exit;}' "$path"/output/helm-values.yaml)"
    yq -i ".global.domainName = \"$domainName\"" "$path"/output/helm-values.yaml || error_exit "domainName modification is failed."

    echo ""
    echo "Adding imagePullSecret"
    yq -i '.global.imagePullSecrets[0].name = "regcred"' "$path"/output/helm-values.yaml || error_exit "imagePullSecrets modification is failed."

    echo ""
    echo "Adding license"
    LICENSE=$(echo "$license" | tr -d "'") yq -i '.global.license = strenv(LICENSE)' "$path"/output/helm-values.yaml || error_exit "license modification is failed."

    echo ""
    echo "Copying Kong annotation to Nginx"
    yq -i '.nginx.annotations'='.kong.annotations' "$path"/output/helm-values.yaml || error_exit "kong annotation modification is failed."

    echo ""
    echo "Configuring AWS ACM"
    if [[ $(yq '.kong.aws_acm.enabled' "$path"/output/helm-values.yaml) == true ]]
    then
        yq -i '.nginx.aws_acm.enabled'='true' "$path"/output/helm-values.yaml || error_exit "kong aws_acm modification is failed."
    fi

    echo ""
    echo "Altering Postgres block for new chart"
    if [[ $(yq '.postgresql.internal' "$path"/output/helm-values.yaml) == true ]]
    then
        yq -i '
            .postgresql.auth.postgresPassword=.postgresql.postgresqlPassword |
            .postgresql.auth.username="" |
            .postgresql.auth.existingSecret=""
            ' "$path"/output/helm-values.yaml || error_exit "postgresqlPassword modification is failed."
    else
        yq -i '
            .postgresql.auth.password=.postgresql.postgresqlPassword |
            .postgresql.auth.username=.postgresql.postgresqlUsername |
            .postgresql.auth.existingSecret=""
            ' "$path"/output/helm-values.yaml || error_exit "postgres username or password modification is failed."
    fi

    echo ""
    echo "Cleaning Nomad Autoscaler Block"
    if [[ $(yq '.nomad.auto_scaler.enabled' "$path"/output/helm-values.yaml) == false ]]
    then
        yq -i 'del(.nomad.auto_scaler.gcp)' "$path"/output/helm-values.yaml || error_exit "Nomad autoscaler (gcp) block deletion is failed"
        yq -i 'del(.nomad.auto_scaler.aws)' "$path"/output/helm-values.yaml || error_exit "Nomad autoscaler (aws) block deletion is failed"
    elif [[ $(yq '.nomad.auto_scaler.aws.enabled' "$path"/output/helm-values.yaml) == true ]]
    then
        yq -i 'del(.nomad.auto_scaler.gcp)' "$path"/output/helm-values.yaml || error_exit "Nomad autoscaler (gcp) block deletion is failed"
    else
        yq -i 'del(.nomad.auto_scaler.aws)' "$path"/output/helm-values.yaml || error_exit "Nomad autoscaler (aws) block deletion is failed"
    fi

    echo ""
    echo "Cleaning VM Block"
    if [[ $(yq '.vm_service.providers.ec2.enabled' "$path"/output/helm-values.yaml) == true ]]
    then
        yq -i 'del(.vm_service.providers.gcp)' "$path"/output/helm-values.yaml || error_exit "VM provider (gcp) block deletion is failed"
    else
        yq -i 'del(.vm_service.providers.aws)' "$path"/output/helm-values.yaml || error_exit "VM provider (aws) block deletion is failed"
    fi

    echo ""
    echo "Cleaning S3 Block"
    if [[ $(yq '.object_storage.s3.enabled' "$path"/output/helm-values.yaml) == true ]]
    then
        yq -i 'del(.object_storage.gcs)' "$path"/output/helm-values.yaml || error_exit "Object Storage (gcp) block deletion is failed"
    else
        yq -i 'del(.object_storage.s3)' "$path"/output/helm-values.yaml || error_exit "Object Storage (aws) block deletion is failed"
    fi

    echo ""
    echo "Deleting discarded values"
    yq -i 'del(.published) |
           del(.domainName) |
           del(.kong.annotations) |
           del(.postgresql.postgresqlUsername) |
           del(.postgresql.postgresqlPassword) |
           del(.nomad.server.rpc.advertise) |
           del(.license)' "$path"/output/helm-values.yaml || echo "Delete manually if exists"
}

annotation_k8s_resource(){
    echo ""
    echo "############ ANNOTATING K8S RESOURCES ################"

    # Adding Labels and Annotations for Helm
    for resource in "${resourceList[@]}";do
        echo "Applying annotations to all $resource resources ..."
        echo ""
        {
        kubectl -n $namespace annotate "$resource" --all meta.helm.sh/release-name=$slug meta.helm.sh/release-namespace=$namespace --overwrite
        kubectl -n $namespace label "$resource" --all app.kubernetes.io/managed-by=Helm --overwrite
        } >> "$path/logs/$annotateLogFile"
    done

    echo "Annotation logs are available - $path/logs/$annotateLogFile"
}

execute_flyway_migration(){
    echo ""
    echo "############ RUNNING FLYWAY DB MIGRATION JOB ################"

    echo "Checking if job/circle-migrator already ran -"
    if kubectl get job/circle-migrator -n $namespace -o name > /dev/null 2>&1
    then
        echo "Job circle-migrator is already been run, If you want to run again, delete the job circle-migrator via below command"
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
    (kubectl wait job/circle-migrator --namespace "$namespace" --for condition="complete" --timeout=300s \
    && echo "++++ DB Migration job is successful." ) \
    || error_exit "Status wait timeout for job/circle-migrator, Check the Log via - kubectl logs pods -l app=circle-migrator"
}

rm_kots_annot_label_resources(){
    echo ""
    echo "############ REMOVING KOTS ANNOTATIONS, LABELS & RESOURCES ############"

    for resource in "${resourceList[@]}";do
        echo "" | tee -a  "$path/logs/$kotsCleanupLogFile"
        echo "Removing kots related annotations/labels on all $resource resources..."
        {
        kubectl -n $namespace annotate "$resource" --all kots.io/app-slug-
        kubectl -n $namespace label "$resource" --all kots.io/app-slug- kots.io/backup-
        } >> "$path/logs/$kotsCleanupLogFile"

        echo "Removing k8s $resource resources if kots.io/kotsadm=true..."
        kubectl -n $namespace delete "$resource"  -l "kots.io/kotsadm=true" | tee -a "$path/logs/$kotsCleanupLogFile"
    done

    echo ""
    kubectl -n $namespace delete secret kotsadm-sessions kotsadm-replicated-registry | tee -a "$path/logs/$kotsCleanupLogFile"

    echo ""
    echo "Deleting kots minio keys "
    yq -i 'del(.minio)' "$path"/output/helm-values.yaml || echo "Delete the minio block manually from $path/output/helm-values.yaml if it exists"

    echo "Kots removal logs are available - $path/logs/$kotsCleanupLogFile"

    echo "Deleting job inject-bottoken-xxxx"
    kubectl -n $namespace delete "$(kubectl -n $namespace get jobs -o name | grep inject)" \
    || echo "Manully run the command: kubectl -n $namespace delete $(kubectl -n $namespace get jobs -o name | grep inject)"
}

output_message(){
    echo ""
    echo "############ HELM COMMANDS ################"

    echo "Output file is here - $path/output/helm-values.yaml"

    echo ""
    echo "To upgrade Postgres Chart (v11.6.0), follow below steps -"
    echo "-------------------------------------------------------------------------"
    echo "export POSTGRESQL_PASSWORD=\$(kubectl get secret --namespace $namespace postgresql -o jsonpath=\"{.data.postgres-password}\" | base64 --decode)"
    echo "export POSTGRESQL_PVC=\$(kubectl get pvc --namespace $namespace -l app.kubernetes.io/instance=circleci-server,role=primary -o jsonpath=\"{.items[0].metadata.name}\")"

    echo "kubectl delete statefulsets.apps postgresql --namespace $namespace --cascade=orphan"
    echo "kubectl delete secret postgresql --namespace $namespace"
    echo "-------------------------------------------------------------------------"

    echo ""
    echo "Helm Diff command (only changes) -"
    echo "-------------------------------------------------------------------------"
    echo "helm diff upgrade $slug -n $namespace -f $path/output/helm-values.yaml --show-secrets --context 5 <chart-directory>"

    echo ""
    echo "Helm upgrade command - "
    echo "-------------------------------------------------------------------------"
    echo "cd <chart-directory>"
    echo "helm dep update"
    echo "helm upgrade $slug -n $namespace -f $path/output/helm-values.yaml <chart-directory> --force"

    echo ""
    domainName="$(awk '/domainName/ {print $2;exit;}' "$path"/output/helm-values.yaml)"
    echo "NOTE: After server 3.x to 4.x migration, You must rerun the Nomad terraform with modified value of 'server_endpoint' variable"
    echo "It should be - $domainName:4647"
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
        -a|--release-name)
            slug="$2";
            shift ;;
        -n|--namespace)
            namespace="$2";
            shift ;;
        -r|--annotate)
            annotate="$2";
            shift ;;
        -l|--license)
            license="$2";
            shift ;;
        -f|--func)
            func="$2";
            shift ;;
        -h|--help)
            help_init_options;
            exit 0 ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

check_prereq
check_required_args
set_default_value
if [[ "$func" == "flyway" ]]; then
    execute_flyway_migration
elif [[ "$func" == "annotate" ]]; then
    annotation_k8s_resource
elif [[ "$func" == "cleanup_kots" ]]; then
    rm_kots_annot_label_resources
elif [[ "$func" == "message" ]]; then
    output_message
elif [[ "$func" == "all" ]]; then
    create_folders
    download_helm_values
    modify_helm_values
    if [[ $annotate == 1 ]]; then
        annotation_k8s_resource
    fi
    execute_flyway_migration
    rm_kots_annot_label_resources
    output_message
else
    echo ""
    echo "############ ERROR ################"
    echo "-f $func is not a valid function"
    help_init_options
fi