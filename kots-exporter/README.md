# server-kots-exportergs

This is a script to download KOTS config and convert it to a `helm` values file

## Prerequisite
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)
- [yq](https://github.com/mikefarah/yq#install)
- [helm](https://github.com/helm/helm#install) (v3.x)
- [helm-diff](https://github.com/databus23/helm-diff#install) (Good to have for comparing helm releases)
- [velero](https://velero.io/docs/v1.6/contributions/minio/#back-up) (Required for backup and restore)

### Docker secret `regcred` must be exists
The Helm chart references private container images. The DockerHub
API token you've been supplied will allow you to pull these images. To do so we need
to create a Docker registry secret in your Kubernetes cluster:

```
$ kubectl create secret docker-registry regcred \
  --docker-server=https://cciserver.azurecr.io/ \
  --docker-username=<image-registry-username> \
  --docker-password=<image-registry-password> \
  --docker-email=<notification-email-id>
```


## Usage

**view arguments:** `./kots-exporter.sh --help`

**command:** `./kots-exporter.sh -n <circleci-app-namespace> -a <release-name> -l <license>`

**example usage:**
```
export namespace=$(helm list --filter 'circle[a-z]+' -o yaml | yq '.[0].namespace' | tr -d '"')
export app_slug=$(helm list --filter 'circle[a-z]+' -o yaml | yq '.[0].name' | tr -d '"')
./kots-exporter.sh -n $namespace -a $app_slug
```

If you want to rerun **Step: RUNNING FLYWAY DB MIGRATION JOB** -
```
./kots-exporter.sh -n <namespace> -a <release-name> -f flyway
```

If you want to rerun **Step: ANNOTATE K8S RESOURCE** only -
```
./kots-exporter.sh -n <namespace> -a <release-name> -f annotate
```

If you want to rerun **Step: REMOVING KOTS ANNOTATIONS, LABELS & RESOURCESg** only -
```
./kots-exporter.sh -n <namespace> -a <release-name> -f kots_cleanup
```

To display the output message -
```
./kots-exporter.sh -n <namespace> -a <release-name> -f message
```

## Developer Usage

**example usage:**
```
# Run the script, but not annotate the k8s resources
./kots-exporter.sh -n <namespace> -a <release-name> -l <license> -r 0
```