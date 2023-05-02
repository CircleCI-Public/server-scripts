#!/usr/bin/env bash

# Read the --hostname argument and --token arguments
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
  --hostname)
    CIRCLECI_HOSTNAME="$2"
    shift
    shift
    ;;
  --token)
    CIRCLECI_TOKEN="$2"
    shift
    shift
    ;;
  *)
    echo "Unknown argument: $1"
    exit 1
    ;;
  esac
done
# Prompt the user for the CircleCI server hostname if there was no argument
if [ -z "${CIRCLECI_HOSTNAME}" ]; then
  read -rp "CircleCI server hostname: " CIRCLECI_HOSTNAME
fi

# Verify the hostname is not empty
if [ -z "${CIRCLECI_HOSTNAME}" ]; then
  echo "CircleCI server hostname cannot be empty"
  exit 1
fi

# Prompt the user for the CircleCI token if there was no argument
if [ -z "${CIRCLECI_TOKEN}" ]; then
  read -rp "CircleCI API token: " CIRCLECI_TOKEN
fi

# Verify the token is not empty
if [ -z "${CIRCLECI_TOKEN}" ]; then
  echo "CircleCI API token cannot be empty"
  exit 1
fi

# Check if contexts.json is empty
if [ ! -s contexts.json ]; then
  echo "No contexts found"
  exit 1
fi

AUTH=$(printf "%s" "${CIRCLECI_TOKEN}:" | base64)

for obj in $(jq -c . contexts.json); do
  # extract the context-id
  context_id=$(echo "${obj}" | jq -r '.["context-id"]')

  # iterate over each context in the contexts array
  for ctx in $(echo "${obj}" | jq -c '.["contexts"][]'); do
    # extract the name and value of the context
    name=$(echo "${ctx}" | jq -r '.["name"]')
    value=$(echo "${ctx}" | jq '.["value"]')

    # Post the data to the CircleCI server API
    # (echo for debug purposes)
    curl --request PUT \
      --url "https://${CIRCLECI_HOSTNAME}/api/v2/context/${context_id}/environment-variable/${name}" \
      --header "Authorization: Basic ${AUTH}" \
      --header "Content-Type: application/json" \
      --data "{\"value\":${value}}"
  done
done
