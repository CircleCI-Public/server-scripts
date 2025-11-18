# Upgrading the MongoDB Image to 7.0

This script is to be used when [upgrading the MongoDB image](https://circleci.com/docs/server-admin/latest/operator/upgrade-mongo/) used in your CircleCI server installs from **4.4** to **7.0**.

You **must complete** the [4.4 upgrade](https://github.com/CircleCI-Public/server-scripts/tree/main/upgrade-mongo-to-4.4) before doing the 7.0 upgrade.

## Prerequisites
- kubectl
- mongoDB is `internal` to your CircleCI server install

## Usage
1. Run: `./upgrade-mongo-image-to-7.0.sh -n <namespace>` 
2. Update the `mongodb` block values.yaml file with the following
```
mongodb:
  ...
  image:
    registry: dockerregistry.logangodsey.com
    repository: mongodb
    tag: 7.0.15-debian-12-r2
    pullSecrets: []
  livenessProbe:
    enabled: false
  readinessProbe:
    enabled: false
  customLivenessProbe:
    exec:
      command:
        - mongosh
        - --eval
        - "db.adminCommand('ping')"
    initialDelaySeconds: 30
    periodSeconds: 10
    timeoutSeconds: 5
    successThreshold: 1
    failureThreshold: 6
  customReadinessProbe:
    exec:
      command:
        - bash
        - -ec
        - |
          mongosh --eval 'db.hello().isWritablePrimary || db.hello().secondary' | grep -q 'true'
    initialDelaySeconds: 5
    periodSeconds: 10
    timeoutSeconds: 5
    successThreshold: 1
    failureThreshold: 6
```