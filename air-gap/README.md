# CircleCI Server in an Air-Gapped Environment

This directory contains scripts for installing CircleCI server in an air-gapped environment.

## Download and Copy Images to Your Air-Gapped Environment

As described in the [air-gapped installation prerequisites](https://circleci.com/docs/server-admin/latest/air-gapped-installation/phase-1-prerequisites/#b-download-all-images-required-for-this-release), you need to download all Docker images required for the release.

The [`extract-images-from-helm-chart.sh`](./extract-images-from-helm-chart.sh) script extracts the Docker images from the server Helm chart so you can copy them to your container registry in your air-gapped environment.

### Dependencies

- [yq](https://mikefarah.gitbook.io/yq): `4.x`

### Steps to Extract Images

1. Download the script to a convenient location:
    ```shell
    curl -fsSL https://raw.githubusercontent.com/CircleCI-Public/server-scripts/main/air-gap/extract-images-from-helm-chart.sh -o extract-images-from-helm-chart.sh
    ```
2. Fetch the Helm chart for inspection. Replace `<version>` with the full version of CircleCI server:
    ```shell
    helm fetch oci://cciserver.azurecr.io/circleci-server --version <version> --untar
    ```
3. Extract images to `images.txt`:
    ```shell
    bash ./extract-images-from-helm-chart.sh ./circleci-server images.txt
    ```

You can now use this list of images to copy to your private container registry.
