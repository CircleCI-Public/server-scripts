# Upgrading the MongoDB Image to 7.0

This script is to be used when [upgrading the MongoDB image](https://circleci.com/docs/server-admin/latest/operator/upgrade-mongo/) used in your CircleCI server installs from **4.4** to **7.0**.

You **must complete** the [4.4 upgrade](https://github.com/CircleCI-Public/server-scripts/tree/main/upgrade-mongo-to-4.4) before doing the 7.0 upgrade.

## Prerequisites
- kubectl
- mongoDB is `internal` to your CircleCI server install

## Usage
1. Run: `./upgrade-mongo-image-to-7.0.sh -n <namespace>`

### Options
| Flag | Description | Default |
|------|-------------|---------|
| `-n, --namespace` | Namespace where your Server is installed | `circleci-server` |
| `-r, --registry` | Image registry to pull MongoDB images from. Defaults to the CircleCI Azure Container Registry. Override this if you are mirroring images to a private registry. | `cciserver.azurecr.io` |

## Images
The script upgrades MongoDB through the following intermediate images before reaching 7.0:

| Image | MongoDB Version |
|-------|----------------|
| `server-mongodb:5.0.24-debian-11-r20` | 5.0 |
| `server-mongodb:6.0.13-debian-11-r21` | 6.0 |
| `server-mongodb:7.0.15-debian-12-r2` | 7.0 |

These images are hosted in the CircleCI Azure Container Registry (`cciserver.azurecr.io`). If you are using a private registry via `--registry`, you must pull each of these images from ACR and push them to your registry before running the script.

2. Update the `mongodb` block values.yaml file with the following
```
mongodb:
  ...
  image:
    registry: cciserver.azurecr.io
    repository: server-mongodb
    tag: 7.0.15-debian-12-r2
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
