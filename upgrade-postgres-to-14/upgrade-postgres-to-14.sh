#!/usr/bin/env bash
#
# Automates the on-disk Postgres 12 → 14 upgrade for CircleCI Server.
# - Auto-discovers PVC, secret, and (while postgres is up) source-cluster
#   encoding/locale. Every value is overridable.
# - If the postgres StatefulSet is still running when the script starts, it
#   captures encoding/locale, then scales postgres to 0 and waits for the
#   underlying volume to detach.
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

INITDB_ENCODING=""
INITDB_LC_COLLATE=""
INITDB_LC_CTYPE=""

UPGRADE_JOB_IMAGE="tianon/postgres-upgrade:12-to-14"
JOB_NAME="postgres-upgrade-12-to-14"

ASSUME_YES=false
DRY_RUN=false

# ============================================================================
# Helpers
# ============================================================================
if [ -t 1 ]; then
  C_RED='\033[1;31m'; C_YEL='\033[1;33m'; C_CYA='\033[1;36m'; C_GRN='\033[1;32m'; C_OFF='\033[0m'
else
  C_RED=''; C_YEL=''; C_CYA=''; C_GRN=''; C_OFF=''
fi

log()  { printf "${C_CYA}[%s]${C_OFF} %s\n" "$SCRIPT_NAME" "$*" >&2; }
ok()   { printf "${C_GRN}[%s]${C_OFF} %s\n" "$SCRIPT_NAME" "$*" >&2; }
warn() { printf "${C_YEL}[%s] WARN:${C_OFF} %s\n" "$SCRIPT_NAME" "$*" >&2; }
err()  { printf "${C_RED}[%s] ERROR:${C_OFF} %s\n" "$SCRIPT_NAME" "$*" >&2; }
die()  { err "$@"; exit 1; }

confirm() {
  $ASSUME_YES && return 0
  local prompt="$1"
  local reply
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

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
                                (default: $UPGRADE_JOB_IMAGE)

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

# ============================================================================
# Resolve image source
# ============================================================================
if $USE_DOCKERHUB; then
  POSTGRES_IMAGE_REPO="$DOCKERHUB_PATH"
  IMAGE_SOURCE_LABEL="Docker Hub"
else
  POSTGRES_IMAGE_REPO="$ACR_PATH"
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
  PVC_NAME=$(discover_single pvc 'app.kubernetes.io/name=postgresql') \
    || die "Could not auto-discover PVC; pass --pvc-name"
  log "  PVC:    $PVC_NAME (discovered)"
else
  log "  PVC:    $PVC_NAME"
fi

if [[ -z "$SECRET_NAME" ]]; then
  SECRET_NAME=$(discover_single secret 'app.kubernetes.io/name=postgresql') \
    || die "Could not auto-discover secret; pass --secret-name"
  log "  Secret: $SECRET_NAME (discovered)"
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

kubectl -n "$NAMESPACE" get pvc "$PVC_NAME" >/dev/null 2>&1 \
  || die "PVC '$PVC_NAME' not found in namespace '$NAMESPACE'"

kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1 \
  || die "Secret '$SECRET_NAME' not found in namespace '$NAMESPACE'"

SECRET_HAS_KEY=$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" \
  -o jsonpath="{.data.$SECRET_KEY}" 2>/dev/null)
[[ -z "$SECRET_HAS_KEY" ]] && die "Secret '$SECRET_NAME' has no key '$SECRET_KEY'"

# Application layer must already be scaled to 0 — they hold the postgres
# connections that would block shutdown. The script leaves their quiesce to
# the operator, but verifies it before doing anything else.
APP_RUNNING=$(kubectl -n "$NAMESPACE" get deploy -l layer=application \
  -o jsonpath='{range .items[?(@.spec.replicas>0)]}{.metadata.name}({.spec.replicas}) {end}' \
  2>/dev/null)
if [[ -n "$APP_RUNNING" ]]; then
  if $DRY_RUN; then
    log "  application deployments: still running ($APP_RUNNING) (would need to be 0 for a real run; dry-run continues)"
  else
    err "Application deployments (layer=application) are still running:"
    err "  $APP_RUNNING"
    err "Scale them down first:"
    err "  kubectl -n $NAMESPACE scale deploy -l layer=application --replicas=0"
    die "Application layer must be at replicas=0 before running this script"
  fi
else
  log "  application deployments (layer=application): all at replicas=0 (good)"
fi

# Postgres StatefulSet state determines what happens next:
#   - Already at 0 → we proceed directly to applying the Job. Locale must
#     come from flags or fall back to Job-script defaults.
#   - Running → capture encoding/locale from the live cluster, then scale
#     postgres to 0 before applying the Job.
SS_REPLICAS=$(kubectl -n "$NAMESPACE" get sts postgresql \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
POSTGRES_NEEDS_SCALE=false
if [[ "$SS_REPLICAS" == "0" ]]; then
  log "  postgres StatefulSet replicas: 0 (already quiesced)"
  if [[ -z "$INITDB_ENCODING" && -z "$INITDB_LC_COLLATE" && -z "$INITDB_LC_CTYPE" ]]; then
    warn "postgres is already at 0 — cannot auto-discover encoding/locale at this point."
    warn "Job script defaults will apply: UTF8 / C.UTF-8 / C.UTF-8."
    warn "If the source cluster uses different settings, pg_upgrade will fail at its locale-compat check."
    warn "Re-run with --initdb-encoding / --initdb-lc-collate / --initdb-lc-ctype to override."
  else
    log "  initdb (explicitly set):    encoding=${INITDB_ENCODING:-<Job default UTF8>} lc_collate=${INITDB_LC_COLLATE:-<Job default C.UTF-8>} lc_ctype=${INITDB_LC_CTYPE:-<Job default C.UTF-8>}"
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

# Existing Job? — only relevant when we're actually going to apply
if ! $DRY_RUN; then
  if kubectl -n "$NAMESPACE" get job "$JOB_NAME" >/dev/null 2>&1; then
    warn "Job '$JOB_NAME' already exists in '$NAMESPACE'."
    confirm "Delete it before proceeding?" || die "Aborted"
    log "  Deleting existing Job..."
    kubectl -n "$NAMESPACE" delete job "$JOB_NAME" --wait=true
  fi
fi

# ============================================================================
# Scale postgres to 0 if needed
# ============================================================================
if $POSTGRES_NEEDS_SCALE && ! $DRY_RUN; then
  log ""
  log "Scaling postgres StatefulSet to 0..."
  confirm "Proceed with scaling postgres down? This takes the database offline." \
    || die "Aborted"
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
    kubectl wait --for=delete "volumeattachment/$VA_FOR_SCALE" --timeout=3m
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
    source-version: "12.16"
    target-version: "14.22"
spec:
  backoffLimit: 0
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
echo ""
printf '%s\n' "$YAML" | sed 's/^/  /'
echo ""

if $DRY_RUN; then
  log "Dry-run mode — exiting without applying."
  exit 0
fi

confirm "Apply this Job?" || die "Aborted"

log ""
log "Applying Job..."
printf '%s\n' "$YAML" | kubectl -n "$NAMESPACE" apply -f -

log "Waiting for pod to be created and ready..."
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod \
  -l "job-name=$JOB_NAME" --timeout=2m 2>&1 || true
sleep 3

log "Streaming Job logs (the Job continues running even if you Ctrl-C the stream)..."
echo ""
kubectl -n "$NAMESPACE" logs -f "job/$JOB_NAME" 2>&1 || true
echo ""

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
     "job/$JOB_NAME" --timeout=2m 2>/dev/null; then
  SUCCEEDED=1
else
  SUCCEEDED=0
fi
FAILED=$(kubectl -n "$NAMESPACE" get job "$JOB_NAME" \
  -o jsonpath='{.status.failed}' 2>/dev/null || echo "")

if [[ "$SUCCEEDED" == "1" ]]; then
  ok "pg_upgrade Job completed successfully."
  cat <<EOF

═══════════════════════════════════════════════════════════════════════════════
NEXT STEPS
═══════════════════════════════════════════════════════════════════════════════

1. UPDATE your helm values file. Replace the postgresql block with:

  postgresql:
    image:
      registry: $POSTGRES_IMAGE_REGISTRY
      repository: $POSTGRES_IMAGE_REPOSITORY
      tag: $PG14_TAG

  (Bitnami's postgresql chart uses split registry/repository/tag fields.
  If your chart wraps it differently, adapt — the full image reference is:
  $FULL_POSTGRES_IMAGE)

2. RUN helm upgrade with the updated values:

  helm upgrade <release-name> <chart-path> -f <your-values-file>.yaml

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

5. AFTER ≥24h of healthy operation, run the Step 7 cleanup from plan.md
   (delete data-12.preupgrade, delete clone PVC if pre-provisioned,
   delete the snapshot).
═══════════════════════════════════════════════════════════════════════════════
EOF
  exit 0
else
  err "pg_upgrade Job did not complete successfully (succeeded='$SUCCEEDED' failed='$FAILED')."
  err "See logs above for diagnostics. Do not blindly retry — the Job's leftover-dir check"
  err "will refuse re-runs while data-12/data-14/upgrade-logs exist on the PVC."
  err "Refer to plan.md 'Re-running after failure' for the cleanup procedure."
  exit 1
fi
