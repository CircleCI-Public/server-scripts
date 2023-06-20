#!/bin/bash

# Declare variables
ARGS="${*:1}"
NAMESPACE="circleci-server"

# Help message for Init menu
help_init_options() {
    echo "  -n|--namespace       Namespace where your Server is installed. Defaults to 'circleci-server'"
    echo "  -h|--help            Print help text"
}

# Handles arguments passed into the init menu
init_options() {
    POSITIONAL=()
    while [[ $# -gt 0 ]]
    do
    key="${1}"
    case $key in
        -n|--namespace)
            shift # need the next arg
            NAMESPACE=$1
            shift # past argument
        ;;
        -h|--help)
            help_init_options
            exit 0
        ;;
        *)    # unknown option
            if [ -n "$1" ] ;
            then
                POSITIONAL+=("${1}") # save it in an array for later
            fi
            shift # past argument
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

# MongoDB variables
MONGO_POD="mongodb-0"
MONGODB_USERNAME="root"
MONGODB_PASSWORD=$(kubectl -n "$NAMESPACE" get secrets mongodb -o jsonpath="{.data.mongodb-root-password}" | base64 --decode)

# List of Mongo image versions
declare -a mongo_images=(
  "4.0.27-debian-9-r118"
  "4.2.17-debian-10-r99"
  "4.4.15-debian-10-r8"
)

# function kubectl patch sts image
function patch_mongo_image() {
  if [ -z "$1" ];
  then
		echo "Please provide mongo compatability version to target"
		exit 1
	fi
  
  result=$(kubectl patch statefulset mongodb --patch "{\"spec\": {\"template\": {\"spec\": {\"containers\": [{\"name\": \"mongodb\",\"image\": \"docker.io/bitnami/mongodb:${1}\"}]}}}}")
  
  #Check if patch ran successfully
  if [[ $result == *"statefulset.apps/mongodb patched"* ]]; 
  then
    echo "MongoDB image set to $1"
  else
    echo "Failed to patch MongoDB statefulset"
    echo $result
    exit 1
  fi
}

# function kubectl set compatibility version
function set_compatibility_version() {
  # check if mongo compatibility version has been passed
  if [ -z "$1" ];
  then
		echo "Please provide mongo compatability version to target"
		exit 1
	fi

  result=$(kubectl exec $MONGO_POD -- mongo -u $MONGODB_USERNAME -p $MONGODB_PASSWORD --eval "db.adminCommand({ setFeatureCompatibilityVersion: '$1' })")

  if [[ $result == *"{ \"ok\" : 1 }"* ]]; 
  then
    echo "MongoDB upgraded to $1"
  else
    echo "Failed to set compatibility version"
    echo $result
    exit 1
  fi
}


for i in "${mongo_images[@]}"
do
  mongo_version=$(echo ${i} | cut -c1-3)

  echo "upgrading Mongodb to $mongo_version using image: $i"
  echo "..."
  patch_mongo_image "$i"
  echo "waiting for mongo pod to restart.."
  sleep 30
  set_compatibility_version "$mongo_version"
done

echo ""
echo ""
echo ""
echo "To complete the upgrade, you will need to edit your values.yaml to match your upgraded image."
echo "Include the following in the mongodb block of your values.yaml:"
echo ""
echo "mongodb:
  ...
  image:
    tag: 4.4.15-debian-10-r8"
echo ""
