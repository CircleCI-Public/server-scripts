# Migrating 3 to 4
**Stop!** You probably want [kots-exporter](../kots-exporter/).  This script should only be used at the recommendation of your CircleCI Contact.

## Prequsites
1. There exists a 4.0 instance where reality check has successfully run.

2. In the 3.4 environment, add the same [docker-registry secret](https://circleci.com/docs/server/installation/phase-2-core-services/#pull-images) that is used in the 4.0 environment

## Using
`./exporter.sh` will export all the datastores from a 3.4 instance onto your local machine.  `./restore.sh` will import the data now on your local machine into the 4.0 environment

### Export data from 3.4
1.  Set the kubectl context to the CircleCI 3.4 instance you are migrating **From**
2.  Run: `./exporter.sh -n <namespace>`

### Import data into 4.0
1.  Set the Kubectl context to the CirlceCI 4.0 instance you are migrating **To**
2.  Run: `./restore.sh <namespace>`
3.  Update CircleCI 4.0 to point at the storage bucket from 3.4
4.  Update Signing and Encryption keys they will be in `circleci_export/encryptkey` and `circleci_export/signkey`
