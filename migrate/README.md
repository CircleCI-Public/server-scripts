# Data Migration

## Migrating from 2.19.x to 3.0

Run `./migrate.sh`. The 2.19.x data will compressed, copied into your current directory, extracted, and uploaded into a 3.0 installation.

You will be prompted for the following:

1. Latest 2.19.x server information:
  * username
  * hostname
  * SSH key file

2. Kubernetes namespace containing a 3.0 installation.
