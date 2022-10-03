#!/bin/bash

##
# CircleCI Server Migration Script
#
#   This script is for installations migrating from the latest CircleCI Server 2.19.x
#   to CircleCI Server 3.x.
#
#   This script will create a tar ball of CircleCI encryption & signing keys,
#   Vault, PostgreSQL and Mongo databases. The tar ball will be copied locally,
#   extracted, and passed through kubectl commands to the 3.x installation.
##

DIR=$(dirname "$0")
ARGS="${*:1}"

# Init

help_init_options() {
    # Help message for Init menu
    echo "  -s|--skip-databases           Skip migrating Postgres and Mongodb data"
    echo "  -p|--skip-postgres            Skip migrating Postgres data"
    echo "  -m|--skip-mongo               Skip migrating Mongodb data"
    echo "  -v|--skip-vault               Skip migrating Vault data"
    echo "     --host                     Hostname of the 2.x installation"
    echo "     --key                      Path to 2.x SSH key file"
    echo "     --user                     Username for 2.x SSH access"
    echo "     --namespace                Namespace of the 3.x OR 4.x install"
    echo "     --server4                  Use when migrating to 4.x"
    echo "  -h|--help                     Print help text"
}

init_options() {
    # Handles arguments passed into the init menu
    POSITIONAL=()
    while [[ $# -gt 0 ]]
    do
    key="${1}"
    case $key in
        -s|--skip-databases)
            SKIP_POSTGRES="--skip-postgres"
            SKIP_MONGO="--skip-mongo"
            shift # past argument
        ;;
        -p|--skip-postgres)
            SKIP_POSTGRES="--skip-postgres"
            shift # past argument
        ;;
        -m|--skip-mongo)
            SKIP_MONGO="--skip-mongo"
            shift # past argument
        ;;
        -v|--skip-vault)
            SKIP_VAULT="--skip-vault"
            shift # past argument
        ;;
        --host)
            shift # need the next arg
            HOST=$1
            shift # past argument
        ;;
        --key)
            shift # need the next arg
            KEY_FILE=$1
            shift # past argument
        ;;
        --user)
            shift # need the next arg
            USERNAME=$1
            shift # past argument
        ;;
        --namespace)
            shift # need the next arg
            NAMESPACE=$1
            shift # past argument
        ;;
        --server4)
            SERVER4="--server4"
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

    SKIP="${SKIP_POSTGRES} ${SKIP_MONGO} ${SKIP_VAULT}"
}

# shellcheck disable=SC2086
init_options $ARGS

if [ ! "$(which jq)" ]
then
    echo ... "'jq' not found. Please install jq locally in order to run this script."
    exit 1
fi

echo "Note: this script assumes passwordless sudo access on the services box."
echo "Additionally, the 2.19.x application will be stopped and not started back up."

echo ""
echo ""

if [[ -z $HOST || -z $KEY_FILE || -z $USERNAME ]];
then
    echo "We need some information before we can begin."
    echo "First, let's start with your 2.19.x installation."
fi

if [ -z "$HOST" ];
then
    read -r -p 'Hostname: ' HOST
fi

if [ -z "$KEY_FILE" ];
then
    read -r -p 'SSH Key File: ' KEY_FILE
fi

if [ -z "$USERNAME" ];
then
    read -r -p 'SSH Username: ' USERNAME
fi

HOST="${USERNAME}@${HOST}"

if [ -z "$NAMESPACE" ];
then
    echo "Now we need the namespace that has CircleCI Server 3.x installed."
    read -r -p 'Namespace: ' NAMESPACE
fi


echo ""
echo "."
echo ".."
echo "..."
echo ""
echo ""

echo "## CircleCI Server Migration ##"

# Tell user which version of server the migration will target
if [ ! "$SERVER4" = "--server4" ];
then
    echo "Migrating to Server 3.x!"
else
    echo "Migrating to Server 4.x!"
fi

echo "...copying export scripts remotely"
scp -i "$KEY_FILE" "${DIR}"/2.19-*.sh "${HOST}":

if [ ! "$SKIP" = "--skip-postgres --skip-mongo --skip-vault" ];
then
    echo "...stopping the application"
    ssh -i "$KEY_FILE" -t "${HOST}" -- "replicatedctl app stop"
    
    echo "...sleeping while the application stops"
    sleep 60
fi

echo "...initiating export"
ssh -i "$KEY_FILE" -t "${HOST}" -- "sudo bash 2.19-export.sh ${SKIP}"

echo "...copying export locally"
scp -i "$KEY_FILE" "${HOST}":circleci_export.tar.gz .

echo "...extracting export"
tar zxvf circleci_export.tar.gz

bash "${DIR}"/3.0-restore.sh "$SKIP" "$NAMESPACE" "$SERVER4"
