#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-circleci-server}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

sed \
  -e "s/namespace: circleci-server/namespace: ${NAMESPACE}/g" \
  -e "s/- circleci-server$/- ${NAMESPACE}/" \
  "${SCRIPT_DIR}/support-bundle-namespaced.yaml" \
  | kubectl support-bundle -
