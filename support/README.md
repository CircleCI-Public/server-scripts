# CircleCI Server Support Bundle

This directory contains support bundle configs for [troubleshoot.sh](https://troubleshoot.sh). They collect and sanitize diagnostic information from a CircleCI Server install to share with the support team.

The manifests defined here are client-side and install no resources on the cluster.

## Prerequisites

1. Make sure CircleCI Server is deployed and you have access to the cluster via `kubectl`. For the namespace-scoped bundle, your kubeconfig must have `get`/`list` permissions on pods, logs, deployments, and events in the target namespace, plus cluster-level read access for `clusterResources`.
2. [Install krew](https://krew.sigs.k8s.io/docs/user-guide/setup/install/).
3. Install the support-bundle plugin:

```bash
kubectl krew install support-bundle
```

## Collecting Support Information

### Namespace-scoped (recommended)

Use `run.sh` to collect data from a specific namespace. Defaults to `circleci-server`:

```bash
# From the repo root
./support/run.sh

# Custom namespace
./support/run.sh my-namespace
```

### Cluster-wide

To collect from all namespaces (useful when the install namespace is unknown):

```bash
kubectl support-bundle support/support-bundle.yaml
```

A sanitized `.tar.gz` will be created in the current directory. Attach it to your support ticket.
