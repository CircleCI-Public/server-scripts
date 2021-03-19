# Data Migration

## Migrating from 2.19.x to 3.0

Run the 2.19-export.sh script as root on a latest 2.19.x install. This will generate a
.tar.gz you can copy locally and extract. From there you can run the restore.sh script,
which assumes you have kubectl installed with the correct context defined, including
the namespace: `kubectl config set-context --current --namespace=$NAMESPACE`

After the import you will need to upload the signing and encryption keys from
the `circle-data` directory to the kots admin console.