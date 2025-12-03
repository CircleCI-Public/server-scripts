#!/bin/bash
set -euo pipefail

if ! command -v yq >/dev/null || ! yq --version | grep -q 'v4.' 2>&1; then
  echo "Error: yq 4.x is required: https://mikefarah.gitbook.io/yq#install" >&2
  yq --version
  exit 1
fi

CHART_PATH="${1:-.}"
OUTPUT_FILE="${2:-images.txt}"

TMP_VALUES=$(mktemp)
TMP_IMAGES=$(mktemp)
trap 'rm -f "$TMP_VALUES" "$TMP_IMAGES"' EXIT

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
