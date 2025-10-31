#!/bin/bash
ARGS="${*:1}"
NAMESPACE="circleci-server"

help_init_options() {
    echo "  -n|--namespace       Namespace where your Server is installed. Defaults to 'circleci-server'"
    echo "  -h|--help            Print help text"
}

init_options() {
    POSITIONAL=()
    while [[ $# -gt 0 ]]
    do
    key="${1}"
    case $key in
        -n|--namespace)
            shift 
            NAMESPACE=$1
            shift 
        ;;
        -h|--help)
            help_init_options
            exit 0
        ;;
        *)
            if [ -n "$1" ] ;
            then
                POSITIONAL+=("${1}")
            fi
            shift 
        ;;
    esac
    done

    if [ ${#POSITIONAL[@]} -gt 0 ]
    then
        help_init_options
        exit 1
    fi
}

init_options $ARGS

MONGO_POD="mongodb-0"
MONGODB_USERNAME="root"
MONGODB_PASSWORD=$(kubectl -n "$NAMESPACE" get secrets mongodb -o jsonpath="{.data.mongodb-root-password}" | base64 --decode)

declare -a mongo_images=(
  "5.0.24-debian-11-r20"
  "6.0.13-debian-11-r21"
  "7.0.15-debian-12-r2"
)

function patch_mongo_image() {
  if [ -z "$1" ];
  then
		echo "Please provide mongo image version to target"
		exit 1
	fi
  
  if [ -z "$2" ];
  then
		echo "Please provide major version"
		exit 1
	fi
  
  local image_tag="$1"
  local major_version="$2"
  
  if [ "$major_version" -ge 5 ]; then
    echo "Patching image and probes for MongoDB $major_version..."
    result=$(kubectl -n "$NAMESPACE" patch statefulset mongodb --type json -p='[
      {
        "op": "replace",
        "path": "/spec/template/spec/containers/0/image",
        "value": "cciserver.azurecr.io/server-mongodb:'"$image_tag"'"
      },
      {
        "op": "replace",
        "path": "/spec/template/spec/containers/0/livenessProbe/exec/command",
        "value": ["mongosh", "--eval", "db.adminCommand(\"ping\")"]
      },
      {
        "op": "replace",
        "path": "/spec/template/spec/containers/0/readinessProbe/exec/command",
        "value": ["mongosh", "--eval", "db.adminCommand(\"ping\")"]
      }
    ]')
  else
    result=$(kubectl -n "$NAMESPACE" patch statefulset mongodb --patch "{\"spec\": {\"template\": {\"spec\": {\"containers\": [{\"name\": \"mongodb\",\"image\": \"cciserver.azurecr.io/server-mongodb:${image_tag}\"}]}}}}")
  fi
  
  if [[ $result == *"statefulset.apps/mongodb patched"* ]]; 
  then
    echo "MongoDB image set to $image_tag"
  else
    echo "Failed to patch MongoDB statefulset"
    echo "$result"
    exit 1
  fi
}

function set_compatibility_version() {
  if [ -z "$1" ];
  then
		echo "Please provide mongo compatibility version to target"
		exit 1
	fi

  major_version=$(echo "$1" | cut -d. -f1)
  if [ "$major_version" -ge 5 ]; then
    shell_cmd="mongosh"
  else
    shell_cmd="mongo"
  fi

  echo "Using $shell_cmd to set compatibility version..."
  
  if [ "$major_version" -ge 7 ]; then
    echo "Note: MongoDB 7.0+ upgrade is one-way and cannot be downgraded without support assistance"
    result=$(kubectl -n "$NAMESPACE" exec "$MONGO_POD" -- $shell_cmd -u "$MONGODB_USERNAME" -p "$MONGODB_PASSWORD" --eval "db.adminCommand({ setFeatureCompatibilityVersion: '$1', confirm: true })")
  else
    result=$(kubectl -n "$NAMESPACE" exec "$MONGO_POD" -- $shell_cmd -u "$MONGODB_USERNAME" -p "$MONGODB_PASSWORD" --eval "db.adminCommand({ setFeatureCompatibilityVersion: '$1' })")
  fi

  if [[ $result == *"{ \"ok\" : 1 }"* ]] || [[ $result == *"ok: 1"* ]]; 
  then
    echo "MongoDB compatibility version set to $1"
  else
    echo "Failed to set compatibility version"
    echo "$result"
    exit 1
  fi
}


for i in "${mongo_images[@]}"
do
  mongo_version=$(echo "${i}" | cut -d- -f1 | cut -d. -f1-2)
  major_version=$(echo "$mongo_version" | cut -d. -f1)

  echo ""
  echo "=========================================="
  echo "Upgrading MongoDB to $mongo_version using image: $i"
  echo "=========================================="
  echo ""
  
  patch_mongo_image "$i" "$major_version"
  
  echo "Waiting for mongo pod to restart..."
  kubectl -n "$NAMESPACE" rollout status statefulset/mongodb --timeout=300s
  
  if [ $? -ne 0 ]; then
    echo "Error: MongoDB pod failed to restart properly"
    exit 1
  fi
  
  echo "Pod restarted successfully. Setting compatibility version..."
  set_compatibility_version "$mongo_version"
  
  echo "MongoDB $mongo_version upgrade complete!"
done

echo ""
echo "=========================================="
echo "MongoDB Upgrade Complete!"
echo "=========================================="
echo ""
echo "To complete the upgrade, you will need to edit your values.yaml to match your upgraded image."
echo "Include the following in the mongodb block of your values.yaml.:"
echo ""
echo "mongodb:"
echo "  image:"
echo "    tag: 7.0.15-debian-12-r2"
echo "    pullSecrets: []"
echo "  livenessProbe:"
echo "    enabled: false"
echo "  readinessProbe:"
echo "    enabled: false"
echo "  customLivenessProbe:"
echo "    exec:"
echo "      command:"
echo "        - mongosh"
echo "        - --eval"
echo "        - \"db.adminCommand('ping')\""
echo "    initialDelaySeconds: 30"
echo "    periodSeconds: 10"
echo "    timeoutSeconds: 5"
echo "    successThreshold: 1"
echo "    failureThreshold: 6"
echo "  customReadinessProbe:"
echo "    exec:"
echo "      command:"
echo "        - bash"
echo "        - -ec"
echo "        - |"
echo "          mongosh --eval 'db.hello().isWritablePrimary || db.hello().secondary' | grep -q 'true'"
echo "    initialDelaySeconds: 5"
echo "    periodSeconds: 10"
echo "    timeoutSeconds: 5"
echo "    successThreshold: 1"
echo "    failureThreshold: 6"
echo ""