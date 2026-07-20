#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# forecast.sh — CircleCI Server compute cost estimator
# Queries conductor_production for job durations and estimates cloud credits
# using historical cloud resource class usage weights.
#
# Usage: ./forecast.sh -n <namespace> [-d <days>] [-H <pg-host>] [-p <pg-port>]
# ------------------------------------------------------------------------------

DAYS=30
PG_PORT=5432
PG_USER=postgres
PG_HOST=""
NAMESPACE=""
SECRET_NAME=""
SECRET_KEY="postgres-password"

usage() {
  cat <<USAGE
Usage: $0 -n <namespace> [-d <days>] [-H <pg-host>] [-p <pg-port>]

  -n  Kubernetes namespace (required)
  -d  Number of days to look back (default: 30)
  -H  Postgres host (default: auto port-forward via kubectl)
  -p  Postgres port (default: 5432)
USAGE
  exit 1
}

while getopts "n:d:H:p:" opt; do
  case $opt in
    n) NAMESPACE="$OPTARG" ;;
    d) DAYS="$OPTARG" ;;
    H) PG_HOST="$OPTARG" ;;
    p) PG_PORT="$OPTARG" ;;
    *) usage ;;
  esac
done

[[ -z "$NAMESPACE" ]] && { echo "Error: -n <namespace> is required"; usage; }

# ------------------------------------------------------------------------------
# Discover PG pod — try app.kubernetes.io/name first (Bitnami), then app label
# (matches the pattern used in server-scripts/upgrade-postgres-to-14)
# ------------------------------------------------------------------------------
echo "Looking up PostgreSQL pod in namespace '$NAMESPACE'..."

PG_POD=$(kubectl -n "$NAMESPACE" get pods \
  -l "app.kubernetes.io/name=postgresql" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$PG_POD" ]]; then
  PG_POD=$(kubectl -n "$NAMESPACE" get pods \
    -l "app=postgresql" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi

if [[ -z "$PG_POD" ]]; then
  echo "Error: Could not find a PostgreSQL pod in namespace '$NAMESPACE'"
  echo "       Tried labels: app.kubernetes.io/name=postgresql, app=postgresql"
  echo "       List pods manually: kubectl -n $NAMESPACE get pods"
  exit 1
fi
echo "   Pod: $PG_POD"

# ------------------------------------------------------------------------------
# Discover secret — try app.kubernetes.io/name label first, then fall back to
# the well-known secret name 'postgresql' (same approach as upgrade script)
# ------------------------------------------------------------------------------
if [[ -z "$SECRET_NAME" ]]; then
  SECRET_NAME=$(kubectl -n "$NAMESPACE" get secret \
    -l "app.kubernetes.io/name=postgresql" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi

if [[ -z "$SECRET_NAME" ]]; then
  if kubectl -n "$NAMESPACE" get secret postgresql &>/dev/null; then
    SECRET_NAME="postgresql"
  fi
fi

if [[ -z "$SECRET_NAME" ]]; then
  echo "Error: Could not auto-discover PostgreSQL secret in namespace '$NAMESPACE'"
  exit 1
fi
echo "   Secret: $SECRET_NAME (key: $SECRET_KEY)"

PG_PASSWORD=$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" \
  -o jsonpath="{.data.$SECRET_KEY}" 2>/dev/null | base64 -d || true)

# Some installs use 'postgresql-password' as the key
if [[ -z "$PG_PASSWORD" ]]; then
  PG_PASSWORD=$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" \
    -o jsonpath='{.data.postgresql-password}' 2>/dev/null | base64 -d || true)
  [[ -n "$PG_PASSWORD" ]] && SECRET_KEY="postgresql-password"
fi

if [[ -z "$PG_PASSWORD" ]]; then
  echo "WARNING: Could not read password from secret '$SECRET_NAME' — will fall back to psql prompt."
fi

# ------------------------------------------------------------------------------
# Port-forward if no external host provided
# ------------------------------------------------------------------------------
if [[ -z "$PG_HOST" ]]; then
  echo "Port-forwarding $PG_POD -> localhost:15432..."
  kubectl -n "$NAMESPACE" port-forward "$PG_POD" 15432:5432 &>/dev/null &
  PF_PID=$!
  trap 'echo ""; echo "Stopping port-forward..."; kill $PF_PID 2>/dev/null || true' EXIT
  sleep 2
  PG_HOST="localhost"
  PG_PORT=15432
fi

# ------------------------------------------------------------------------------
# SQL query
# ------------------------------------------------------------------------------
SQL=$(cat <<ENDSQL
WITH job_stats AS (
    SELECT
        COUNT(*)                                                                        AS total_jobs,
        ROUND(SUM(EXTRACT(EPOCH FROM (e.ended_at - s.started_at)) / 60)::numeric, 2)   AS total_minutes
    FROM public.job_started_events s
    JOIN public.job_ended_events e ON e.job_id = s.job_id
    WHERE s.started_at >= NOW() - INTERVAL '$DAYS days'
      AND e.ended_at > s.started_at
),
resource_classes AS (
    SELECT * FROM (VALUES
        ('small',   0.189979,  6),
        ('medium',  0.428673, 12),
        ('large',   0.310874, 24),
        ('xlarge',  0.065853, 48),
        ('2xlarge', 0.004621, 96)
    ) AS t(resource_class, weight, credits_per_minute)
),
breakdown AS (
    SELECT
        rc.resource_class,
        ROUND((js.total_minutes * rc.weight)::numeric, 2)                           AS estimated_minutes,
        ROUND((js.total_minutes * rc.weight * rc.credits_per_minute)::numeric, 2)   AS estimated_credits
    FROM job_stats js
    CROSS JOIN resource_classes rc
)
SELECT resource_class, total_jobs, estimated_minutes, estimated_credits
FROM (
    SELECT
        resource_class,
        NULL::bigint AS total_jobs,
        estimated_minutes,
        estimated_credits,
        0 AS sort_order
    FROM breakdown
    UNION ALL
    SELECT
        '── TOTAL ──',
        js.total_jobs,
        ROUND(SUM(b.estimated_minutes)::numeric, 2),
        ROUND(SUM(b.estimated_credits)::numeric, 2),
        1 AS sort_order
    FROM breakdown b
    CROSS JOIN job_stats js
    GROUP BY js.total_jobs
) t
ORDER BY sort_order, estimated_credits DESC NULLS LAST;
ENDSQL
)

# ------------------------------------------------------------------------------
# Run query
# ------------------------------------------------------------------------------
echo ""
echo "CircleCI Server Compute Cost Forecast (last $DAYS days)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

PGPASSWORD="$PG_PASSWORD" psql \
  -h "$PG_HOST" \
  -p "$PG_PORT" \
  -U "$PG_USER" \
  -d conductor_production \
  --pset="border=2" \
  --pset="format=aligned" \
  -c "$SQL"

echo ""
echo "NOTE: Resource class breakdown uses CircleCI usage weights as a proxy."
echo "   Actual distribution may vary. Credits are estimates, not exact billing figures."