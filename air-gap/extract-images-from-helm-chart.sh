#!/bin/bash
set -euo pipefail

CHART_PATH=$(realpath "${1:-.}")
OUTPUT_FILE="${2:-images.txt}"

TMP_VALUES=$(mktemp)
TMP_IMAGES=$(mktemp)
trap 'rm -f "$TMP_VALUES" "$TMP_IMAGES"' EXIT

# Check if yq 4.x is available locally, otherwise use Docker
if ! command -v yq >/dev/null || ! yq --version 2>&1 | grep -q 'v4\.'; then
  echo "yq 4.x not found locally, using Docker image mikefarah/yq:4" >&2
  yq() {
    docker run --rm -i \
      -u "$(id -u)" \
      -v "${CHART_PATH}:${CHART_PATH}" \
      -v "/tmp:/tmp" \
      -w "${PWD}" \
      mikefarah/yq:4 "$@"
  }
fi

# Enable all components to ensure everything renders and we find all images
yq '
  (.. | select(has("enabled")).enabled) = true
  | (.. | select(has("isEnabled")).isEnabled) = true
' "$CHART_PATH/values.yaml" > "$TMP_VALUES"

# Set required values so templating won't fail
yq -i '
  .oidc_service.json_web_keys = "dummy"
' "$TMP_VALUES"

# Extract images from rendered manifests
# See: https://stackoverflow.com/a/64436933
helm template "$CHART_PATH" \
  --values "$TMP_VALUES" \
  --skip-schema-validation \
  | yq -N e '..|.image? | select(.)' - \
  > "$TMP_IMAGES"

# Extract picard (build-agent) image from images.yaml as this image is not used directly in a deployment,
# but is referenced by docker-provisioner
picard_tag=$(yq -r '.["circleci/picard"]' "$CHART_PATH/images.yaml")
echo "circleci/picard:$picard_tag" >> "$TMP_IMAGES"

sort -u "$TMP_IMAGES" > "$OUTPUT_FILE"
echo "Created $OUTPUT_FILE"
