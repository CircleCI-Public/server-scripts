#!/usr/bin/env bash
#
# Automates the on-disk Postgres 12 → 14 upgrade for CircleCI Server.
# - Auto-discovers PVC, secret, and source-cluster encoding/locale. Every
#   value is overridable.
# - If the postgres StatefulSet is running, captures encoding/locale, then
#   scales postgres to 0 and waits for the underlying volume to detach.
# - If postgres is already at 0 and any --initdb-* flag is missing, briefly
#   scales postgres back to 1 to query template1, then returns it to 0.
# - Renders the pg_upgrade Job manifest, applies it, streams logs, and
#   verifies completion via `kubectl wait --for=condition=Complete`.
# - On success, prints the helm values block to update and reminds the
#   operator to run `helm upgrade` manually.
#
# PREREQUISITES (operator's responsibility):
#   - Application-layer deployments (label `layer=application`) scaled to 0.
#     The script refuses to proceed if any are still running.
#   - Snapshot or PVC clone of the source PVC (platform-specific).
#
# DOES NOT do: app-layer scale-down, snapshot, validation, or post-upgrade
# cleanup. The `helm upgrade` after a successful run restores correct
# replica counts for postgres and the application layer.
#
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

# ============================================================================
# Defaults (override via flags)
# ============================================================================
NAMESPACE=""
PVC_NAME=""
SECRET_NAME=""
SECRET_KEY="postgres-password"
PG14_TAG="14.22.4094-4922444"

ACR_PATH="cciserver.azurecr.io/circleci/server-postgres"
DOCKERHUB_PATH="circleci/server-postgres"
USE_DOCKERHUB=false

# pg_upgrade Job image. Defaults to ACR; --dockerhub switches it to Docker Hub.
# An explicit --upgrade-job-image overrides both (UPGRADE_JOB_IMAGE starts empty
# so we can tell whether the operator set it).
ACR_UPGRADE_IMAGE="cciserver.azurecr.io/server-postgres-upgrade:12-14"
DOCKERHUB_UPGRADE_IMAGE="circleci/server-postgres-upgrade:12-14"

INITDB_ENCODING=""
INITDB_LC_COLLATE=""
INITDB_LC_CTYPE=""

UPGRADE_JOB_IMAGE=""
JOB_NAME="postgres-upgrade-12-to-14"

ASSUME_YES=false
DRY_RUN=false

# ============================================================================
# Helpers
# ============================================================================
if [ -t 2 ]; then
  C_RED='\033[1;31m'; C_YEL='\033[1;33m'; C_CYA='\033[1;36m'; C_GRN='\033[1;32m'; C_OFF='\033[0m'
else
  C_RED=''; C_YEL=''; C_CYA=''; C_GRN=''; C_OFF=''
fi

log()  { printf "${C_CYA}[%s]${C_OFF} %s\n" "$SCRIPT_NAME" "$*" >&2; }
ok()   { printf "${C_GRN}[%s]${C_OFF} %s\n" "$SCRIPT_NAME" "$*" >&2; }
warn() { printf "${C_YEL}[%s] WARN:${C_OFF} %s\n" "$SCRIPT_NAME" "$*" >&2; }
err()  { printf "${C_RED}[%s] ERROR:${C_OFF} %s\n" "$SCRIPT_NAME" "$*" >&2; }
die()  { err "$@"; exit 1; }

validate() {
  local label="$1" value="$2" regex="$3"
  [[ "$value" =~ $regex ]] || die "Invalid $label value '$value' (must match $regex)"
}

confirm() {
  $ASSUME_YES && return 0
  local prompt="$1"
  local reply
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

command -v kubectl >/dev/null 2>&1 \
  || die "kubectl is required and must be in PATH"

# ============================================================================
# Usage
# ============================================================================
usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --namespace NS [options]

Automates Step 4 (Run pg_upgrade) of the postgres 12 → 14 runbook. Renders
the Job manifest with auto-discovered cluster values, applies it, streams
logs, and prints the helm values block to update on success.

REQUIRED:
  -n, --namespace NS            Namespace where the postgres StatefulSet runs

OPTIONAL:
  -t, --pg14-tag TAG            PG14 server-postgres image tag
                                (default: $PG14_TAG)

OPTIONAL — auto-discovered from a standard Bitnami install if omitted:
      --pvc-name NAME           Source PVC (default: discovered via labels)
      --secret-name NAME        K8s secret with postgres password (default: discovered)
      --secret-key KEY          Key within the secret (default: $SECRET_KEY)
      --initdb-encoding ENC     New cluster encoding (default: discovered from live cluster, else UTF8)
      --initdb-lc-collate LOC   New cluster LC_COLLATE (default: discovered, else C.UTF-8)
      --initdb-lc-ctype LOC     New cluster LC_CTYPE (default: discovered, else C.UTF-8)

IMAGE SOURCE:
      --dockerhub               Pull server-postgres from Docker Hub instead of ACR
      --acr-path PATH           ACR repo path (default: $ACR_PATH)
      --upgrade-job-image IMG   Image for the pg_upgrade Job
                                (default: $ACR_UPGRADE_IMAGE;
                                 $DOCKERHUB_UPGRADE_IMAGE with --dockerhub)

EXECUTION:
  -y, --yes                     Skip confirmation prompts
      --dry-run                 Print the rendered Job YAML and exit
  -h, --help                    Show this help

EXAMPLES:
  $SCRIPT_NAME -n circleci-server
  $SCRIPT_NAME -n circleci-server -t 14.22.0-othertag
  $SCRIPT_NAME -n circleci-server --dockerhub
  $SCRIPT_NAME -n circleci-server \\
      --pvc-name data-postgresql-0 --secret-name my-postgres-secret \\
      --initdb-lc-collate en_US.UTF-8 --initdb-lc-ctype en_US.UTF-8 -y
EOF
}

# ============================================================================
# Arg parsing
# ============================================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)         NAMESPACE="$2"; shift 2 ;;
    -t|--pg14-tag)          PG14_TAG="$2"; shift 2 ;;
        --pvc-name)         PVC_NAME="$2"; shift 2 ;;
        --secret-name)      SECRET_NAME="$2"; shift 2 ;;
        --secret-key)       SECRET_KEY="$2"; shift 2 ;;
        --initdb-encoding)  INITDB_ENCODING="$2"; shift 2 ;;
        --initdb-lc-collate) INITDB_LC_COLLATE="$2"; shift 2 ;;
        --initdb-lc-ctype)  INITDB_LC_CTYPE="$2"; shift 2 ;;
        --dockerhub)        USE_DOCKERHUB=true; shift ;;
        --acr-path)         ACR_PATH="$2"; shift 2 ;;
        --upgrade-job-image) UPGRADE_JOB_IMAGE="$2"; shift 2 ;;
    -y|--yes)               ASSUME_YES=true; shift ;;
        --dry-run)          DRY_RUN=true; shift ;;
    -h|--help)              usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

[[ -z "$NAMESPACE" ]] && { usage; die "--namespace is required"; }
[[ -z "$PG14_TAG"  ]] && die "--pg14-tag is empty (internal default was cleared?)"

# Validate user-supplied values before they reach kubectl invocations or the
# rendered YAML. Auto-discovered values come from kubectl/psql output and are
# trusted (k8s enforces DNS-1123 names; postgres uses C identifiers for
# encoding/locale names).
validate "--namespace"  "$NAMESPACE"  '^[a-z0-9][a-z0-9.-]*$'
validate "--secret-key" "$SECRET_KEY" '^[A-Za-z0-9._-]+$'
[[ -n "$PVC_NAME"          ]] && validate "--pvc-name"          "$PVC_NAME"          '^[a-z0-9][a-z0-9.-]*$'
[[ -n "$SECRET_NAME"       ]] && validate "--secret-name"       "$SECRET_NAME"       '^[a-z0-9][a-z0-9.-]*$'
[[ -n "$INITDB_ENCODING"   ]] && validate "--initdb-encoding"   "$INITDB_ENCODING"   '^[A-Za-z0-9._@-]+$'
[[ -n "$INITDB_LC_COLLATE" ]] && validate "--initdb-lc-collate" "$INITDB_LC_COLLATE" '^[A-Za-z0-9._@-]+$'
[[ -n "$INITDB_LC_CTYPE"   ]] && validate "--initdb-lc-ctype"   "$INITDB_LC_CTYPE"   '^[A-Za-z0-9._@-]+$'

# ============================================================================
# Resolve image source
# ============================================================================
if $USE_DOCKERHUB; then
  POSTGRES_IMAGE_REPO="$DOCKERHUB_PATH"
  UPGRADE_JOB_IMAGE="${UPGRADE_JOB_IMAGE:-$DOCKERHUB_UPGRADE_IMAGE}"
  IMAGE_SOURCE_LABEL="Docker Hub"
else
  POSTGRES_IMAGE_REPO="$ACR_PATH"
  UPGRADE_JOB_IMAGE="${UPGRADE_JOB_IMAGE:-$ACR_UPGRADE_IMAGE}"
  IMAGE_SOURCE_LABEL="ACR ($ACR_PATH)"
fi
FULL_POSTGRES_IMAGE="$POSTGRES_IMAGE_REPO:$PG14_TAG"

# Split image repo into registry/repository for the helm values snippet.
# Docker image-reference rules: the first segment is treated as a registry
# hostname only if it contains a `.`, a `:`, or is exactly `localhost`.
# Otherwise it's a Docker Hub username and the whole string is the repository
# under docker.io.
FIRST_SEGMENT="${POSTGRES_IMAGE_REPO%%/*}"
if [[ "$FIRST_SEGMENT" == "$POSTGRES_IMAGE_REPO" ]]; then
  # No slash at all, e.g. just "postgres"
  POSTGRES_IMAGE_REGISTRY="docker.io"
  POSTGRES_IMAGE_REPOSITORY="$POSTGRES_IMAGE_REPO"
elif [[ "$FIRST_SEGMENT" == *.* || "$FIRST_SEGMENT" == *:* || "$FIRST_SEGMENT" == "localhost" ]]; then
  # First segment is a registry hostname (e.g. cciserver.azurecr.io)
  POSTGRES_IMAGE_REGISTRY="$FIRST_SEGMENT"
  POSTGRES_IMAGE_REPOSITORY="${POSTGRES_IMAGE_REPO#*/}"
else
  # First segment is a Docker Hub user (e.g. circleci/server-postgres → docker.io / circleci/server-postgres)
  POSTGRES_IMAGE_REGISTRY="docker.io"
  POSTGRES_IMAGE_REPOSITORY="$POSTGRES_IMAGE_REPO"
fi

# ============================================================================
# Auto-discovery
# ============================================================================
discover_single() {
  # $1 = resource kind, $2 = label selector
  local kind="$1" selector="$2"
  local names
  names=$(kubectl -n "$NAMESPACE" get "$kind" -l "$selector" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  local count
  count=$(echo "$names" | wc -w | tr -d ' ')
  case "$count" in
    0) return 1 ;;
    1) echo "$names" ;;
    *) err "Multiple $kind match '$selector' in '$NAMESPACE': $names"
       err "Specify explicitly via the appropriate flag."
       return 2 ;;
  esac
}

discover_locale() {
  # Returns 0 if locale info was discovered into INITDB_* vars, 1 otherwise.
  local pgp info
  pgp=$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" \
    -o jsonpath="{.data.$SECRET_KEY}" 2>/dev/null | base64 -d 2>/dev/null) || return 1
  [[ -z "$pgp" ]] && return 1
  info=$(kubectl -n "$NAMESPACE" exec postgresql-0 -- \
    env PGPASSWORD="$pgp" psql -U postgres -tAc \
    "SELECT pg_encoding_to_char(encoding) || '|' || datcollate || '|' || datctype FROM pg_database WHERE datname='template1'" \
    2>/dev/null) || return 1
  [[ -z "$info" || "$info" != *"|"* ]] && return 1
  INITDB_ENCODING="${INITDB_ENCODING:-${info%%|*}}"
  local tmp="${info#*|}"
  INITDB_LC_COLLATE="${INITDB_LC_COLLATE:-${tmp%|*}}"
  INITDB_LC_CTYPE="${INITDB_LC_CTYPE:-${tmp##*|}}"
}

log "Discovering defaults from namespace '$NAMESPACE'..."

if [[ -z "$PVC_NAME" ]]; then
  rc=0; PVC_NAME=$(discover_single pvc 'app.kubernetes.io/name=postgresql') || rc=$?
  case "$rc" in
    0) log "  PVC:    $PVC_NAME (discovered)" ;;
    1) die "Could not auto-discover PVC; pass --pvc-name" ;;
    *) exit 1 ;;
  esac
else
  log "  PVC:    $PVC_NAME"
fi

if [[ -z "$SECRET_NAME" ]]; then
  rc=0; SECRET_NAME=$(discover_single secret 'app.kubernetes.io/name=postgresql') || rc=$?
  case "$rc" in
    0) log "  Secret: $SECRET_NAME (discovered)" ;;
    1) die "Could not auto-discover secret; pass --secret-name" ;;
    *) exit 1 ;;
  esac
else
  log "  Secret: $SECRET_NAME"
fi
log "  Secret key: $SECRET_KEY"

# Locale discovery is deferred — it depends on whether the postgres pod is
# still running when we get to the pre-check phase. If it is, we'll query
# template1 there. If it's not, we'll either use the values passed via
# flags or fall back to Job script defaults (UTF8 / C.UTF-8 / C.UTF-8).

# ============================================================================
# Pre-checks
# ============================================================================
log ""
log "Pre-checks:"

CURRENT_CTX=$(kubectl config current-context)
log "  kubectl context: $CURRENT_CTX"

kubectl get ns "$NAMESPACE" >/dev/null 2>&1 \
  || die "Namespace '$NAMESPACE' does not exist in context '$CURRENT_CTX'"

# Pod Security Admission: a namespace enforcing `restricted` will reject the
# Job because it needs to run as root (UID 0) to bridge the upgrade image's
# UID 999 and the chart's UID 1001 via chown.
PSS_ENFORCE=$(kubectl get ns "$NAMESPACE" \
  -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)
if [[ "$PSS_ENFORCE" == "restricted" ]]; then
  err "Namespace '$NAMESPACE' enforces Pod Security 'restricted' admission."
  err "The pg_upgrade Job needs to run as root (UID 0) for a chown step that"
  err "bridges the upgrade image's UID 999 and the chart's UID 1001."
  err "Remediation: temporarily relax the label before re-running, e.g.:"
  err "  kubectl label ns $NAMESPACE pod-security.kubernetes.io/enforce=baseline --overwrite"
  err "Restore the original label after the upgrade completes."
  die "Pod Security 'restricted' enforcement blocks this Job"
fi
log "  Pod Security enforce label: ${PSS_ENFORCE:-<unset>}"

kubectl -n "$NAMESPACE" get pvc "$PVC_NAME" >/dev/null 2>&1 \
  || die "PVC '$PVC_NAME' not found in namespace '$NAMESPACE'"

kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1 \
  || die "Secret '$SECRET_NAME' not found in namespace '$NAMESPACE'"

SECRET_HAS_KEY=$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" \
  -o jsonpath="{.data.$SECRET_KEY}" 2>/dev/null)
[[ -z "$SECRET_HAS_KEY" ]] && die "Secret '$SECRET_NAME' has no key '$SECRET_KEY'"

kubectl -n "$NAMESPACE" get sts postgresql >/dev/null 2>&1 \
  || die "StatefulSet 'postgresql' not found in namespace '$NAMESPACE' (this script targets the standard CircleCI Server install)"

# Application layer must already be scaled to 0 — they hold the postgres
# connections that would block shutdown. The script leaves their quiesce to
# the operator, but verifies it before doing anything else. Checks both
# Deployments and StatefulSets (some app-layer workloads are STS).
APP_DEPLOY_RUNNING=$(kubectl -n "$NAMESPACE" get deploy -l layer=application \
  -o jsonpath='{range .items[?(@.spec.replicas>0)]}{.metadata.name}({.spec.replicas}) {end}' \
  2>/dev/null)
APP_STS_RUNNING=$(kubectl -n "$NAMESPACE" get sts -l layer=application \
  -o jsonpath='{range .items[?(@.spec.replicas>0)]}{.metadata.name}({.spec.replicas}) {end}' \
  2>/dev/null)
APP_RUNNING=$(echo "$APP_DEPLOY_RUNNING $APP_STS_RUNNING" | tr -s ' ' | sed 's/^ //;s/ $//')
if [[ -n "$APP_RUNNING" ]]; then
  if $DRY_RUN; then
    log "  application workloads: still running ($APP_RUNNING) (would need to be 0 for a real run; dry-run continues)"
  else
    err "Application workloads (layer=application) are still running:"
    err "  $APP_RUNNING"
    err "Scale them down first:"
    err "  kubectl -n $NAMESPACE scale deploy -l layer=application --replicas=0"
    err "  kubectl -n $NAMESPACE scale sts -l layer=application --replicas=0"
    die "Application layer must be at replicas=0 before running this script"
  fi
else
  log "  application workloads (layer=application): all at replicas=0 (good)"
fi

# Postgres StatefulSet state determines what happens next:
#   - Running → capture encoding/locale from the live cluster, then scale
#     postgres to 0 before applying the Job.
#   - Already at 0 → if any --initdb-* flag is missing, briefly scale postgres
#     back to 1 to query template1, then let the standard scale-down path
#     return it to 0. If postgres won't come up or the query fails, hard-fail
#     with a remediation message — silently falling back to defaults caused
#     a pg_upgrade locale-compat abort in earlier runs.
SS_REPLICAS=$(kubectl -n "$NAMESPACE" get sts postgresql \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
POSTGRES_NEEDS_SCALE=false
POSTGRES_BOUNCED=false
if [[ "$SS_REPLICAS" == "0" ]]; then
  log "  postgres StatefulSet replicas: 0 (already quiesced)"
  if [[ -n "$INITDB_ENCODING" && -n "$INITDB_LC_COLLATE" && -n "$INITDB_LC_CTYPE" ]]; then
    log "  initdb (explicitly set):    encoding=$INITDB_ENCODING lc_collate=$INITDB_LC_COLLATE lc_ctype=$INITDB_LC_CTYPE"
  else
    log "  initdb locale not fully specified — temporarily scaling postgres back to 1 to query template1"
    if $DRY_RUN; then
      warn "  dry-run: would scale postgres up, query locale, then scale it back down"
    else
      kubectl -n "$NAMESPACE" scale sts postgresql --replicas=1 >/dev/null
      log "  waiting for postgresql-0 to be Ready..."
      kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/postgresql-0 --timeout=5m >/dev/null \
        || die "postgres did not become Ready within 5m after scale-up. Either troubleshoot postgres, scale it up yourself and wait until Ready before re-running, or re-run with --initdb-encoding / --initdb-lc-collate / --initdb-lc-ctype set explicitly."
      discover_locale \
        || die "postgres came up but template1 locale query failed (auth or psql issue). Re-run with --initdb-encoding / --initdb-lc-collate / --initdb-lc-ctype set explicitly."
      log "  initdb (discovered after bounce): encoding=$INITDB_ENCODING lc_collate=$INITDB_LC_COLLATE lc_ctype=$INITDB_LC_CTYPE"
      POSTGRES_NEEDS_SCALE=true
      POSTGRES_BOUNCED=true
    fi
  fi
else
  log "  postgres StatefulSet replicas: $SS_REPLICAS — script will capture locale, then scale it to 0"
  POSTGRES_NEEDS_SCALE=true
  if [[ -z "$INITDB_ENCODING" || -z "$INITDB_LC_COLLATE" || -z "$INITDB_LC_CTYPE" ]]; then
    if discover_locale 2>/dev/null; then
      log "  initdb (discovered live):   encoding=$INITDB_ENCODING lc_collate=$INITDB_LC_COLLATE lc_ctype=$INITDB_LC_CTYPE"
    else
      warn "Could not query postgresql-0 for encoding/locale even though the pod appears up."
      warn "Job script defaults will apply: UTF8 / C.UTF-8 / C.UTF-8."
      warn "If those don't match the source, pg_upgrade will fail at its locale-compat check."
    fi
  else
    log "  initdb (explicitly set):    encoding=$INITDB_ENCODING lc_collate=$INITDB_LC_COLLATE lc_ctype=$INITDB_LC_CTYPE"
  fi
fi

# Existing Job? — only relevant when we're actually going to apply. This is
# a surprise (operator didn't expect a leftover), so it gets its own confirm
# separate from the consolidated "planned actions" prompt below.
if ! $DRY_RUN; then
  if kubectl -n "$NAMESPACE" get job "$JOB_NAME" >/dev/null 2>&1; then
    warn "Job '$JOB_NAME' already exists in '$NAMESPACE'."
    confirm "Delete it before proceeding?" || die "Aborted"
    log "  Deleting existing Job..."
    kubectl -n "$NAMESPACE" delete job "$JOB_NAME" --wait=true
  fi
fi

# ============================================================================
# Consolidated confirmation — one prompt covers every planned action below
# ============================================================================
if ! $DRY_RUN; then
  log ""
  log "═══════════════════════════════════════════════════════════════════"
  log "Planned actions (no further prompts after this one):"
  if $POSTGRES_NEEDS_SCALE; then
    if $POSTGRES_BOUNCED; then
      log "  • Scale StatefulSet 'postgresql' back to 0 (was scaled up briefly to read locale)"
    else
      log "  • Scale StatefulSet 'postgresql' to 0 (takes the database offline)"
    fi
    log "  • Wait for the underlying volume to detach"
  fi
  log "  • Apply pg_upgrade Job '$JOB_NAME' against PVC '$PVC_NAME'"
  log "  • Stream Job logs and wait for completion"
  log "═══════════════════════════════════════════════════════════════════"
  log ""
  confirm "Proceed with all of the above?" || die "Aborted"
fi

# ============================================================================
# Scale postgres to 0 if needed
# ============================================================================
if $POSTGRES_NEEDS_SCALE && ! $DRY_RUN; then
  log ""
  log "Scaling postgres StatefulSet to 0..."
  kubectl -n "$NAMESPACE" scale sts postgresql --replicas=0
  log "  waiting for postgresql-0 pod to terminate..."
  kubectl -n "$NAMESPACE" wait --for=delete pod/postgresql-0 --timeout=5m

  log "  waiting for volume to detach (cloud-side detach round-trip)..."
  PV_FOR_SCALE=$(kubectl -n "$NAMESPACE" get pvc "$PVC_NAME" \
    -o jsonpath='{.spec.volumeName}')
  VA_FOR_SCALE=$(kubectl get volumeattachment \
    -o jsonpath='{range .items[?(@.spec.source.persistentVolumeName=="'"$PV_FOR_SCALE"'")]}{.metadata.name}{end}' \
    2>/dev/null || true)
  if [[ -n "$VA_FOR_SCALE" ]]; then
    kubectl wait --for=delete "volumeattachment/$VA_FOR_SCALE" --timeout=10m
    log "  volume fully detached"
  else
    log "  no VolumeAttachment found; volume already detached"
  fi
fi

# ============================================================================
# Render YAML
# ============================================================================
render_yaml() {
  cat <<HEADER
# Rendered by $SCRIPT_NAME on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Namespace:         $NAMESPACE
# Source PVC:        $PVC_NAME
# Secret:            $SECRET_NAME (key: $SECRET_KEY)
# Target image:      $FULL_POSTGRES_IMAGE  [from $IMAGE_SOURCE_LABEL]
# pg_upgrade image:  $UPGRADE_JOB_IMAGE
# initdb defaults:   encoding=${INITDB_ENCODING:-<Job default UTF8>} lc_collate=${INITDB_LC_COLLATE:-<Job default C.UTF-8>} lc_ctype=${INITDB_LC_CTYPE:-<Job default C.UTF-8>}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $NAMESPACE
  labels:
    purpose: pg-major-upgrade
    source-major: "12"
    target-version: "14.22"
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        app.kubernetes.io/name: postgres-upgrade
    spec:
      restartPolicy: Never
      securityContext:
        runAsUser: 0
        runAsGroup: 0
        fsGroup: 0
      containers:
        - name: pg-upgrade
          image: $UPGRADE_JOB_IMAGE
          imagePullPolicy: IfNotPresent
          env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: $SECRET_NAME
                  key: $SECRET_KEY
HEADER

  [[ -n "$INITDB_ENCODING" ]] && cat <<ENV_ENC
            - name: INITDB_ENCODING
              value: "$INITDB_ENCODING"
ENV_ENC

  [[ -n "$INITDB_LC_COLLATE" ]] && cat <<ENV_COLLATE
            - name: INITDB_LC_COLLATE
              value: "$INITDB_LC_COLLATE"
ENV_COLLATE

  [[ -n "$INITDB_LC_CTYPE" ]] && cat <<ENV_CTYPE
            - name: INITDB_LC_CTYPE
              value: "$INITDB_LC_CTYPE"
ENV_CTYPE

  # Quoted heredoc — $VARs inside stay literal so the in-container bash
  # sees them properly. (Note: any value injected from outside MUST be
  # done via separate sections, not inside this block.)
  cat <<'BASH_BODY'
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail
              PGROOT=/bitnami/postgresql
              CUR=$PGROOT/data
              OLD=$PGROOT/data-12
              NEW=$PGROOT/data-14
              ARCHIVED=$PGROOT/data-12.preupgrade
              LOGS=$PGROOT/upgrade-logs
              UPGRADE_UID=999
              UPGRADE_GID=999
              CHART_UID=1001
              CHART_GID=1001

              echo "==> [1/7] Verifying PG 12 cluster at $CUR"
              if [[ ! -f "$CUR/PG_VERSION" ]]; then
                echo "FATAL: $CUR/PG_VERSION not found."; exit 1
              fi
              VER=$(cat "$CUR/PG_VERSION")
              if [[ "$VER" != "12" ]]; then
                echo "FATAL: expected PG_VERSION=12, found '$VER'"; exit 1
              fi
              if [[ -d "$OLD" || -d "$NEW" || -d "$ARCHIVED" ]]; then
                echo "FATAL: leftover dir(s) from a prior run found under $PGROOT."
                ls -la "$PGROOT" || true
                exit 1
              fi

              echo "==> [2/7] Staging directories and configs"
              mv "$CUR" "$OLD"
              mkdir -p "$NEW" "$LOGS"
              chmod 0700 "$OLD" "$NEW"

              if [[ ! -f "$OLD/postgresql.conf" ]]; then
                echo "    injecting minimal postgresql.conf"
                printf '%s\n' \
                  '# Minimal postgresql.conf written by the pg_upgrade Job.' \
                  '# pg_upgrade overrides connection settings via -c on pg_ctl.' \
                  > "$OLD/postgresql.conf"
              fi
              if [[ ! -f "$OLD/pg_hba.conf" ]]; then
                echo "    injecting minimal pg_hba.conf"
                printf '%s\n' \
                  '# Minimal pg_hba.conf written by the pg_upgrade Job.' \
                  '# Trust local connections so pg_upgrade can read catalogs.' \
                  'local all all trust' \
                  'host  all all 127.0.0.1/32 trust' \
                  'host  all all ::1/128      trust' \
                  > "$OLD/pg_hba.conf"
              fi

              chown -R ${UPGRADE_UID}:${UPGRADE_GID} "$OLD" "$NEW" "$LOGS"

              echo "==> [3/7] initdb new PG14 cluster"
              INITDB_ENCODING="${INITDB_ENCODING:-UTF8}"
              INITDB_LC_COLLATE="${INITDB_LC_COLLATE:-C.UTF-8}"
              INITDB_LC_CTYPE="${INITDB_LC_CTYPE:-C.UTF-8}"
              echo "    encoding=$INITDB_ENCODING lc_collate=$INITDB_LC_COLLATE lc_ctype=$INITDB_LC_CTYPE"
              gosu postgres /usr/lib/postgresql/14/bin/initdb \
                -D "$NEW" \
                --encoding="$INITDB_ENCODING" \
                --lc-collate="$INITDB_LC_COLLATE" \
                --lc-ctype="$INITDB_LC_CTYPE"

              echo "==> [4/7] Running pg_upgrade --link (jobs=4)"
              cd "$LOGS"
              gosu postgres /usr/lib/postgresql/14/bin/pg_upgrade \
                --old-bindir=/usr/lib/postgresql/12/bin \
                --new-bindir=/usr/lib/postgresql/14/bin \
                --old-datadir="$OLD" \
                --new-datadir="$NEW" \
                --link \
                --jobs=4

              echo "==> [5/7] Verifying new cluster"
              NEWVER=$(cat "$NEW/PG_VERSION")
              if [[ "$NEWVER" != "14" ]]; then
                echo "FATAL: new cluster PG_VERSION='$NEWVER', expected 14."; exit 1
              fi

              echo "==> [6/7] Swapping data dirs into place"
              mv "$OLD" "$ARCHIVED"
              mv "$NEW" "$CUR"

              echo "==> [7/7] Restoring chart's uid:gid (${CHART_UID}:${CHART_GID}) on $CUR"
              chown -R ${CHART_UID}:${CHART_GID} "$CUR"

              echo "==> Done. PG 14 cluster is at $CUR."
              ls -la "$PGROOT"
              ls -la "$LOGS"
BASH_BODY

  cat <<FOOTER
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              cpu: "2"
              memory: 2Gi
          volumeMounts:
            - name: postgres-data
              mountPath: /bitnami/postgresql
      volumes:
        - name: postgres-data
          persistentVolumeClaim:
            claimName: $PVC_NAME
FOOTER
}

YAML=$(render_yaml)

# ============================================================================
# Show + confirm + apply
# ============================================================================
log ""
log "Rendered Job manifest:"
echo "" >&2
printf '%s\n' "$YAML" | sed 's/^/  /' >&2
echo "" >&2

if $DRY_RUN; then
  log "Dry-run mode — exiting without applying."
  exit 0
fi

log ""
log "Applying Job..."
printf '%s\n' "$YAML" | kubectl -n "$NAMESPACE" apply -f -

log "Waiting for pod to be created and ready..."
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod \
  -l "job-name=$JOB_NAME" --timeout=10m 2>&1 || true
sleep 3

log "Streaming Job logs (the Job continues running even if you Ctrl-C the stream)..."
echo "" >&2
kubectl -n "$NAMESPACE" logs -f "job/$JOB_NAME" 2>&1 || true
echo "" >&2

# ============================================================================
# Verify success
# ============================================================================
# `kubectl logs -f` returns the moment the pod terminates, but the Job
# controller takes a beat to reconcile and update .status.succeeded.
# Use `kubectl wait` for the Complete condition instead of polling
# .status.succeeded directly — wait blocks until the condition is true
# or times out.
log ""
log "Waiting for the Job controller to record completion..."
if kubectl -n "$NAMESPACE" wait --for=condition=Complete \
     "job/$JOB_NAME" --timeout=10m 2>/dev/null; then
  SUCCEEDED=1
else
  SUCCEEDED=0
fi
FAILED=$(kubectl -n "$NAMESPACE" get job "$JOB_NAME" \
  -o jsonpath='{.status.failed}' 2>/dev/null || echo "")

if [[ "$SUCCEEDED" == "1" ]]; then
  ok "pg_upgrade Job completed successfully."
  cat >&2 <<EOF

═══════════════════════════════════════════════════════════════════════════════
NEXT STEPS
═══════════════════════════════════════════════════════════════════════════════

1. UPDATE your helm values file. Ensure the following three fields under
   postgresql.image are set to:

      registry: $POSTGRES_IMAGE_REGISTRY
      repository: $POSTGRES_IMAGE_REPOSITORY
      tag: $PG14_TAG

  (Bitnami's postgresql chart uses split registry/repository/tag fields.
  If your chart wraps it differently, adapt — the full image reference is:
  $FULL_POSTGRES_IMAGE)

2. RUN helm upgrade with the updated values:

  helm upgrade circleci-server \\
    oci://cciserver.azurecr.io/circleci-server \\
    --version <server-version> \\
    -f <path-to-your-values-file>

  The StatefulSet will roll with the new image and start against the
  upgraded data directory at /bitnami/postgresql/data.

3. VALIDATE once the new pod is Ready:

  PGP=\$(kubectl -n $NAMESPACE get secret $SECRET_NAME \\
    -o jsonpath='{.data.$SECRET_KEY}' | base64 -d)
  kubectl -n $NAMESPACE exec -it postgresql-0 -- \\
    env PGPASSWORD="\$PGP" psql -U postgres -c 'SELECT version();'
  kubectl -n $NAMESPACE exec -it postgresql-0 -- \\
    env PGPASSWORD="\$PGP" vacuumdb -U postgres --all --analyze-in-stages

4. SCALE application deployments back up:

  kubectl -n $NAMESPACE scale deploy -l layer=application --replicas=1
  for d in \$(kubectl -n $NAMESPACE get deploy -l layer=application -o name); do
    kubectl -n $NAMESPACE rollout status "\$d" --timeout=10m
  done

5. AFTER ≥24h of healthy operation, complete the cleanup steps from
   README → "Clean up" (step 8): delete the data-12.preupgrade dir inside
   the postgres pod, delete your snapshot, and delete the clone PVC if
   you pre-provisioned one. (The upgrade Job auto-deletes 24h after
   completion via ttlSecondsAfterFinished.)
═══════════════════════════════════════════════════════════════════════════════
EOF
  exit 0
else
  err "pg_upgrade Job did not complete successfully (succeeded='$SUCCEEDED' failed='$FAILED')."
  err "See logs above for diagnostics. Do not blindly retry — the Job's leftover-dir check"
  err "will refuse re-runs while data-12/data-14/upgrade-logs exist on the PVC."
  err "See README.md → 'Re-running after a failed Job' for the cleanup procedure."
  exit 1
fi
