#!/usr/bin/env bash

# -------------------------- Variables ---------------------------------

EMPTY=0
ERRED=0
SUCCESS=0
TOTAL=0
ORG_TOTAL=0
ORG_NOT_EXISTS=0
ORG_EXISTS=0
TS=$(date +%Y%m%d-%H%M%S)
LOG="run-log-import-contexts-${TS}.log"

exec > >(tee -i "${LOG}")
exec 2>&1
# -------------------------- End: Variables ---------------------------------


# -------------------------- Processing Args ---------------------------------
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
  --retry)
    INPUT_FILE="$2"
    shift
    shift
    ;;
  *)
    echo "Unknown argument: $1"
    echo "Usage: ./import-contexts.sh --hostname <CCI.SERVER.COM> --token <API.TOKEN> [ --retry <INPUT.FILE> ]"
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

if [ -z "${INPUT_FILE}" ]; then
  INPUT_FILE="contexts.json"
  echo "Using contexts.json input file"
fi

# Check if contexts.json is empty
if [ ! -s "${INPUT_FILE}" ]; then
  echo "No Input file given"
  exit 1
fi
# -------------------------- End: Processing Args ---------------------------------


# -------------------------- Processing Contexts ---------------------------------
while read -r obj; do
  # extract the context-id
  context_id=$(echo "${obj}" | jq -r '.["context-id"]')
  ((TOTAL=TOTAL+1))

# iterate over each context in the contexts array
  org_id=$(echo "${obj}" | jq -r '.["organization-ref"]')

  # Fetch the org name from table if Org is new in loop
  if [ "${old_org_id}" != "${org_id}" ]; then
    org_name=$(kubectl exec postgresql-0 -- bash -c "PGPASSWORD=\$POSTGRES_PASSWORD PAGER= psql -t -U postgres -d domain -c \"SELECT name FROM domain.orgs where id='${org_id}'\";" )
    ((ORG_TOTAL=ORG_TOTAL+1))  # +1 total unique org counter
  fi

  # if Org name is empty
  if [ -z "${org_name}" ] ; then
    if [ "${old_org_id}" != "${org_id}" ]; then
      echo "Org ${org_id} (${org_name}) is no longer exists, hence not processing contexts for this Org"
      ((ORG_NOT_EXISTS=ORG_NOT_EXISTS+1)) # +1 org not exists in system
    fi
    old_org_id="${org_id}"
    continue  # continue the loop for next iteration, not executing further steps
  fi

  echo "Org ${org_id} (${org_name}): processing"
  ((ORG_EXISTS=ORG_EXISTS+1))
  old_org_id="${org_id}"


  while read -r ctx; do
    if [ "${ctx}" == '[]' ]; then
       echo "context id: ${context_id} No ENV VAR to import"
       ((EMPTY=EMPTY+1))
       continue
    fi
    ctx=$(echo "${ctx}" | jq -c '.[]')
    # extract the name and value of the context
    name=$(echo "${ctx}" | jq -r '.["name"]')
    value=$(echo "${ctx}" | jq '.["value"]')


    # Post the data to the CircleCI server API
    echo ""> response.txt
    HTTP_CODE=$(curl -s -o response.txt -w "%{http_code}" --request PUT \
      --url "https://${CIRCLECI_HOSTNAME}/api/v2/context/${context_id}/environment-variable/${name}" \
      --header "Circle-Token: ${CIRCLECI_TOKEN}" \
      --header "Content-Type: application/json" \
      --data "{\"value\":${value}}")
    RESPONSE=$(jq '.message' response.txt)


    if [ "${HTTP_CODE}" != 200 ]; then
      ((ERRED=ERRED+1))
      echo "context id: ${context_id} has failed to import (${HTTP_CODE}: ${RESPONSE})"
      echo "${obj}" >> "contexts_retry_${TS}.json"
      break
    fi
    echo "context id: ${context_id} has imported (${HTTP_CODE}: ${RESPONSE})"
    ((SUCCESS=SUCCESS+1))
  done < <(echo -n "${obj}" | jq -c '.["contexts"]')  # parsing contexts from each line object
done < <(jq -c . "${INPUT_FILE}")  # reading input file

# -------------------------- End: Processing Contexts ---------------------------------


echo "--------------------------------------------------"
if [ -f "contexts_retry_${TS}.json" ]; then
echo ""
echo "There are some failure while importing the contexts"
echo "You have to rerun the script as below -"
echo "./import-contexts.sh --hostname ${CIRCLECI_HOSTNAME} --token ${CIRCLECI_TOKEN} --retry contexts_retry_${TS}.json"
fi


echo ""
echo "${ORG_TOTAL}: Total no of Org for which contexts to import"
echo "${ORG_NOT_EXISTS}: Org no more exists"
echo "${ORG_EXISTS}: Org exists"

echo ""
echo "${TOTAL}: Total contexts to import"
echo "${EMPTY}: Empty contexts"
echo "${ERRED}: Error while importing"
echo "${SUCCESS}: Success imported contexts"

echo ""
echo "Run log: ${LOG}"
echo "--------------------------------------------------"

rm response.txt 2>/dev/null
