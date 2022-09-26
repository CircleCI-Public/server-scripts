# CircleCI Helm Chart Support Bundle
This directory contains a support bundle for troubleshoot.sh. It allows users to collect and sanitize information about a specific install, to send to support for additional debugging.

The manifests defined in this directory are client-side, and install no resources on the cluster.


## Prerequisites

1. First, make sure circleci-server is deployed and you have access to the cluster/namespace through kubectl.
2. Next, [install krew](https://krew.sigs.k8s.io/docs/user-guide/setup/install/).


3. Install preflight and support bundle to your local development machine.

```bash
kubectl krew install preflight
kubectl krew install support-bundle
```

## Collecting Support Information (Development)

### Collecting Information
When ready, run the support bundle from the current directory and wait for it to finish.

```bash
# Within the server/support directory
kubectl support-bundle --namespace=<namespace> support-bundle.yaml
```

A sanitized .tar.gz file will be created in the current directory - this can be sent to the support team for further debugging.
