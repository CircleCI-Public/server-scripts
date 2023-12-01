# Vault to Tink

## Prerequisites

1. The public internet is accessible OR lein dependencies are pre-cached
1. The kubectl context needs to be in the correct namespace (`kubectl config set-context --current --namespace <namespace>`)
1. Docker is running and accessible without `sudo` to run the `clojure` container
1. `jq` is installed.
1. The API token from your Kubernetes secret is accessible to be used for the import.
1. The Postgres server is internal to the CircleCI installation

   - If Postgres has been externalized, please reach out to your account representative.

1. You have a [Tink keyset](https://developers.google.com/tink/install-tinkey) ready to go with `tinkey create-keyset --key-template XCHACHA20_POLY1305`
   - To successfully run the aforementioned command, Java must be installed. On a Mac you may `brew install openjdk`.

1. If on a Mac, please `brew install iproute2mac`

Note: This script will open one REPL per context ID, where one ID is one context; not to be confused with individual variables within a context. If you have a firewall that will rate-limit you, please take that into consideration before proceeding.

Warning: There will be downtime for jobs using contexts during this migration; specifically after updating the `values.yaml` and before the import script finishes.

Warning: Exporting contexts will create a file on your system named `contexts.json`. This file will contain all the names and values of your secrets. It is strongly recommended to `rm -f contexts.json` after importing the contexts and verifying the system operates as expected.

## Preparation

1. Run a job that uses contexts and verify it worked as expected.

## Export

1. Navigate to this directory in your terminal
1. Run `bash export-contexts.sh`

## Moving to Tink

1. Update your `values.yaml` to reference Tink and disable Vault:

```
tink:
  enabled: true
  keyset: '{"primaryKeyId":1981846258,"key":[{"keyData":{"typeUrl":"type.googleapis.com/google.crypto.tink.XChaCha20Poly1305Key","value":"GiCibSVjG2+bLaeShz+M67BcsEZt7GPI+zcE8J+HKYew==","keyMaterialType":"SYMMETRIC"},"status":"ENABLED","keyId":1981846258,"outputPrefixType":"TINK"}]}'
vault:
  internal: false
```

## Import
1. Get your API token by running `API_TOKEN=$(kubectl get secrets api-token -o jsonpath="{.data.api-token}" -n <namespace> | base64 --decode)`
1. Run the import script `bash import-contexts.sh [--hostname <circleci-hostname>] [--token $API_TOKEN]`

## Verification

1. Trigger the same pipeline as the preparation phase to ensure contexts work as expected. _If things do not work as expected, please reach out to your account representitive._
