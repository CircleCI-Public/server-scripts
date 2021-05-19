#!/bin/bash

DIR=$(dirname $0)

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
scp -i $KEY_FILE ${DIR}/2.19-export-vault.sh ${HOST}:

echo "...sleeping while the application stops"
sleep 60

#echo "...initiating export"
ssh -i $KEY_FILE -t $HOST -- "sudo bash 2.19-export.sh"

echo "...copying export locally"
scp -i $KEY_FILE ${HOST}:circleci_export_vault.tar.gz .

echo "...extracting export"
tar zxvf circleci_export_vault.tar.gz

bash ${DIR}/restore-vault.sh $NAMESPACE