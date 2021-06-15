#!/bin/bash

##
# CircleCI Server Migration Script
#
#   This script is for installations migratinf rom the latest CircleCI Server 2.19.x
#   to CircleCI Server 3.0.
#
#   This script will create a tar ball of CircleCI encryption & signing keys,
#   Vault, PostgreSQL and Mongo databases. The tar ball will be copied locally,
#   extracted, and passed through kubectl commands to the 3.0 installation.
##

DIR=$(dirname $0)
SKIP_DATABASE_IMPORT="false"

# Init

help_init_options() {
    # Help message for Init menu
    echo "  -s|--skip-databases           Skip importing Postgres and Mongodb data locally"
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
            SKIP_DATABASE_IMPORT="--skip-databases"
            shift # past argument
        ;;
        -h|--help)
            help_init_options
            exit 0
        ;;
        *)    # unknown option
            POSITIONAL+=("${1}") # save it in an array for later
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

echo "Note: this script assumes passwordless sudo access on the services box."
echo "Additionally, the 2.19.x application will be stopped and not started back up."

echo ""
echo ""

echo "We need some information before we can begin."
echo "First, let's start with your 2.19.x installation."
read -p 'Hostname: ' HOSTNAME
read -p 'SSH key file: ' KEY_FILE
read -p '(SSH) Username: ' USERNAME
HOST="${USERNAME}@${HOSTNAME}"

echo "Now we need the namespace that has CircleCI Server 3.0 installed."
read -p 'Namespace: ' NAMESPACE

echo ""
echo "."
echo ".."
echo "..."
echo ""
echo ""

echo "## CircleCI Server Migration ##"

echo "...stopping the application"
ssh -i $KEY_FILE -t $HOST -- "replicatedctl app stop"

echo "...copying export script remotely"
scp -i $KEY_FILE ${DIR}/2.19-*.sh ${HOST}:

echo "...sleeping while the application stops"
sleep 60

#echo "...initiating export"
ssh -i $KEY_FILE -t $HOST -- "sudo bash 2.19-export.sh ${SKIP_DATABASE_IMPORT}"

echo "...copying export locally"
scp -i $KEY_FILE ${HOST}:circleci_export.tar.gz .

echo "...extracting export"
tar zxvf circleci_export.tar.gz

bash ${DIR}/3.0-restore.sh $SKIP_DATABASE_IMPORT $NAMESPACE