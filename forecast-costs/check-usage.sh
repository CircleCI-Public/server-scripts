#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# check-usage.sh — CircleCI Server compute cost forecast
#
# Estimates what a CircleCI Server install's workload would cost on CircleCI
# Cloud, by reading the install's own build records over its HTTP API and pricing
# them against published Cloud credit rates.
#
# This is a FORECAST, not a billing invoice.
#
# Requires only curl, jq and awk — no kubectl, no psql, no port-forward, and no
# database credentials.
#
# Usage: ./check-usage.sh -u <server-url> [-d <days>] [-g <gen>] [-m <max>] [-o <dir>]
# ------------------------------------------------------------------------------

DAYS=30
SERVER_URL=""
GEN="gen1"
MAX_BUILDS=2000
PAGE=200
OUT_DIR=""

usage() {
  cat <<USAGE
Usage: $0 -u <server-url> [-d <days>] [-g <gen>] [-m <max-builds>] [-o <dir>]

  -u  Base URL of the CircleCI Server install (required), e.g. https://circleci.example.com
  -d  Look-back window in days (default: 30)
  -g  Cloud resource-class generation to price against: gen1 or gen2 (default: gen1)
  -m  Safety cap on how many builds to examine (default: 2000)
  -o  Write per-build detail to <dir>/builds.tsv
  -h  Show this help

Authentication:
  Set CIRCLE_SERVER_TOKEN to an API token for an account with admin scope on the
  install. The build listing endpoint is admin-only. Never hardcode the token.

    export CIRCLE_SERVER_TOKEN='...'
    $0 -u https://circleci.example.com -d 90

Why gen1 by default:
  CircleCI Server supports only gen1 x86 Docker resource classes, whose CPU/RAM
  match Cloud gen1 exactly, so gen1 prices a like-for-like migration.

  Pass -g gen2 to price the same workload on gen2 instead. gen2 is not uniformly
  dearer: Docker gen2 costs ~20% more per minute, while Linux VM gen2 is cheaper
  at xlarge and above (72 vs 100 credits/min at xlarge) and dearer at medium and
  large. The net effect depends entirely on your resource-class mix. gen2 also
  runs faster, so applying gen2 rates to durations measured on gen1 hardware
  overstates the result for the classes that cost more.
USAGE
  exit "${1:-1}"
}

while getopts "u:d:g:m:o:h" opt; do
  case $opt in
    u) SERVER_URL="$OPTARG" ;;
    d) DAYS="$OPTARG" ;;
    g) GEN="$OPTARG" ;;
    m) MAX_BUILDS="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    h) usage 0 ;;
    *) usage ;;
  esac
done

[[ -z "$SERVER_URL" ]] && { echo "Error: -u <server-url> is required" >&2; usage; }
[[ -z "${CIRCLE_SERVER_TOKEN:-}" ]] && {
  echo "Error: CIRCLE_SERVER_TOKEN is not set." >&2
  echo "       export CIRCLE_SERVER_TOKEN='<token>'   # admin scope required" >&2
  exit 1
}
case "$GEN" in gen1|gen2) ;; *) echo "Error: -g must be gen1 or gen2" >&2; exit 1 ;; esac
for tool in curl jq awk; do
  command -v "$tool" >/dev/null || { echo "Error: $tool is required" >&2; exit 1; }
done

SERVER_URL="${SERVER_URL%/}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BUILDS="$WORK/builds.tsv"

api() { curl -sS -H "Circle-Token: $CIRCLE_SERVER_TOKEN" "$@"; }

# Cutoff as an ISO-8601 string, compared lexically (safe for Zulu timestamps).
if date -u -d '1 day ago' >/dev/null 2>&1; then
  CUTOFF="$(date -u -d "$DAYS days ago" '+%Y-%m-%dT%H:%M:%SZ')"   # GNU
else
  CUTOFF="$(date -u -v-"${DAYS}"d '+%Y-%m-%dT%H:%M:%SZ')"         # BSD/macOS
fi

echo "CircleCI Server compute cost forecast"
echo "  server : $SERVER_URL"
echo "  window : last $DAYS days (since $CUTOFF)"
echo "  pricing: Cloud $GEN rates"
echo ""

# ------------------------------------------------------------------------------
# 1. Enumerate builds in the window.
#
# The admin listing is newest-first and supports offset, so page through it until
# a whole page falls outside the window. A whole page — not the first old row —
# because the ordering is only approximately chronological, so a single stale row
# is not proof that the window has ended.
# ------------------------------------------------------------------------------
printf 'slug\tvcs\n' > "$WORK/in_window.tsv"
offset=0
scanned=0
while [[ "$scanned" -lt "$MAX_BUILDS" ]]; do
  # Clamp the page to whatever budget is left, so -m bounds the builds actually
  # examined rather than only the number of pages requested.
  remaining=$(( MAX_BUILDS - scanned ))
  this_page=$(( remaining < PAGE ? remaining : PAGE ))

  if ! api "$SERVER_URL/api/v1/admin/recent-builds?limit=$this_page&offset=$offset" -o "$WORK/page.json"; then
    echo "Error: could not read /api/v1/admin/recent-builds" >&2
    echo "       Check -u, and that the token has admin scope." >&2
    exit 1
  fi
  if ! jq -e 'type == "array"' "$WORK/page.json" >/dev/null 2>&1; then
    echo "Error: unexpected response from the listing endpoint. First 200 bytes:" >&2
    head -c 200 "$WORK/page.json" >&2; echo >&2
    exit 1
  fi

  got="$(jq 'length' "$WORK/page.json")"
  [[ "$got" -eq 0 ]] && break

  # Rows still inside the window. Fall back to queued_at where start_time is
  # absent (a build that never started still has a queue time).
  jq -r --arg cutoff "$CUTOFF" '
    .[] | select(((.start_time // .queued_at) // "") >= $cutoff)
        | [ ((.username // "-") + "/" + (.reponame // "-") + "/" + (.build_num|tostring)),
            (if (.vcs_url // "") | test("bitbucket") then "bitbucket" else "github" end)
          ] | @tsv' "$WORK/page.json" >> "$WORK/in_window.tsv"

  fresh="$(jq -r --arg cutoff "$CUTOFF" \
    '[.[] | select(((.start_time // .queued_at) // "") >= $cutoff)] | length' "$WORK/page.json")"

  scanned=$((scanned + got))
  offset=$((offset + got))
  printf '\r  scanned %d builds, %d in window' "$scanned" "$(( $(wc -l < "$WORK/in_window.tsv") - 1 ))" >&2

  [[ "$fresh" -eq 0 ]] && break        # entire page older than the cutoff
  [[ "$got" -lt "$this_page" ]] && break    # end of the list
done
printf '\n' >&2

IN_WINDOW=$(( $(wc -l < "$WORK/in_window.tsv") - 1 ))
[[ "$IN_WINDOW" -gt 0 ]] || { echo "No builds in the last $DAYS days — nothing to forecast."; exit 0; }

# ------------------------------------------------------------------------------
# 2. Fetch per-build detail.
#
# The resource class and executor are ONLY on the per-build detail response — the
# listing endpoint returns "picard": null, which makes them look unavailable.
# Duration also differs between the two: the listing includes queued time, which
# Cloud does not bill, so the detail value is the correct basis.
# ------------------------------------------------------------------------------
echo "Reading resource class and executor for $IN_WINDOW builds..." >&2
printf 'num\tproject\tjob\texecutor\tclass\tcpu\tram_mb\tparallel\tms\tstarted\tdlc\n' > "$BUILDS"

done_n=0
while IFS=$'\t' read -r slug vcs; do
  [[ "$slug" == "slug" ]] && continue
  if api "$SERVER_URL/api/v1.1/project/$vcs/$slug" -o "$WORK/d.json" 2>/dev/null; then
    jq -r '[ (.build_num|tostring),
             ((.username // "-") + "/" + (.reponame // "-")),
             (.workflows.job_name // "-"),
             (.picard.executor // "unknown"),
             (.picard.resource_class.class // "unknown"),
             ((.picard.resource_class.cpu // 0)|tostring),
             ((.picard.resource_class.ram // 0)|tostring),
             ((.parallel // 1)|tostring),
             ((.build_time_millis // 0)|tostring),
             (if .start_time == null then "no" else "yes" end),
             # Docker Layer Caching leaves a "DLC Teardown" step behind, so it is
             # detectable from step names without reading the job config.
             (if ([.steps[]?.name // ""] | map(select(test("DLC|docker.?layer.?cach";"i"))) | length) > 0
              then "yes" else "no" end) ] | @tsv' "$WORK/d.json" >> "$BUILDS"
  fi
  done_n=$((done_n + 1))
  printf '\r  %d/%d' "$done_n" "$IN_WINDOW" >&2
done < "$WORK/in_window.tsv"
printf '\n\n' >&2

[[ -n "$OUT_DIR" ]] && { mkdir -p "$OUT_DIR"; cp "$BUILDS" "$OUT_DIR/builds.tsv"; }

# ------------------------------------------------------------------------------
# 3. Aggregate and price.
# ------------------------------------------------------------------------------
awk -v gen="$GEN" -v days="$DAYS" '
BEGIN {
  FS = "\t"          # portable: FPAT is a gawk-only extension
  DLC_CREDITS_PER_JOB = 200
  MAX_MS = 86400000  # 24h backstop; Server caps job run time at 5h by default

  # Cloud credit rates, credits per minute.
  # Source: https://circleci.com/pricing/price-list/ — re-verify before quoting.
  if (gen == "gen2") {
    r["docker:small"]=6;   r["docker:medium"]=12; r["docker:medium+"]=18
    r["docker:large"]=24;  r["docker:xlarge"]=48; r["docker:2xlarge"]=96
    r["docker:2xlarge+"]=120
    r["linux:medium"]=18;  r["linux:large"]=36;   r["linux:xlarge"]=72
    r["linux:2xlarge"]=144; r["linux:2xlarge+"]=288
  } else {
    r["docker:small"]=5;   r["docker:medium"]=10; r["docker:medium+"]=15
    r["docker:large"]=20;  r["docker:xlarge"]=40; r["docker:2xlarge"]=80
    r["docker:2xlarge+"]=100
    r["linux:medium"]=10;  r["linux:large"]=20;   r["linux:xlarge"]=100
    r["linux:2xlarge"]=200; r["linux:2xlarge+"]=300
  }

  # Remote Docker (setup_remote_docker) is provisioned as a VM and bills off the
  # Linux VM table, not the Docker table — "billing is based on the VM resource
  # class used". Its reported specs confirm it: a remotedocker "large" comes back
  # as 4 CPU / 15360 MB, which is Linux VM large, not Docker large (4 / 8192).
  # Documented class-to-VM mapping: small/medium -> medium, medium+/large ->
  # large, then one for one.
  r["remotedocker:small"]  = r["linux:medium"]; r["remotedocker:medium"]   = r["linux:medium"]
  r["remotedocker:medium+"] = r["linux:large"];  r["remotedocker:large"]    = r["linux:large"]
  r["remotedocker:xlarge"] = r["linux:xlarge"]; r["remotedocker:2xlarge"]  = r["linux:2xlarge"]
  r["remotedocker:2xlarge+"] = r["linux:2xlarge+"]

  # Windows VMs are priced the same in both generations.
  r["windows:medium"]=40; r["windows:large"]=120
  r["windows:xlarge"]=210; r["windows:2xlarge"]=500
}
NR == 1 { next }
{
  exec_t = $4; cls = $5; par = $8 + 0; ms = $9 + 0; started = $10; dlc = $11
  if (par < 1) par = 1

  # A build that never started consumed no compute and bills nothing. Those
  # builds report build_time_millis = 9223372036854 (Long.MAX_VALUE ms), because
  # the duration derives from a null start_time; taken at face value that inflates
  # a total by orders of magnitude. start_time is the causal test — MAX_MS is only
  # a backstop, and the sentinel is excluded rather than clamped, since clamping
  # would bill a job that never ran as 24 hours.
  #
  # Do NOT filter on outcome instead: a genuinely FAILED build that did run
  # consumed compute and is billable.
  if (started != "yes") { skip_nostart++; next }
  if (ms <= 0)          { skip_zero++;    next }
  if (ms > MAX_MS)      { skip_huge++;    next }

  # Parallelism multiplies billable minutes: N executors for M minutes bills N*M.
  minutes = (ms / 60000.0) * par
  key = exec_t ":" cls

  jobs[key]++; mins[key] += minutes
  if (exec_t == "runner")  rate[key] = 0        # runner jobs incur no compute credits
  else if (key in r)       rate[key] = r[key]
  else                   { rate[key] = -1; unmapped[key] = 1 }

  if (dlc == "yes") { dlc_jobs++ }
  total_minutes += minutes; counted++
}
END {
  dlc_credits = dlc_jobs * DLC_CREDITS_PER_JOB

  printf "%-34s %8s %14s %16s\n", "EXECUTOR : CLASS", "JOBS", "MINUTES", "CREDITS"
  printf "%-34s %8s %14s %16s\n", "----------------------------------", "--------", "--------------", "----------------"
  for (k in jobs) {
    if (rate[k] >= 0) {
      c = mins[k] * rate[k]
      printf "%-34.34s %8d %14.2f %16.1f\n", k, jobs[k], mins[k], c
      compute += c
    } else {
      printf "%-34.34s %8d %14.2f %16s\n", k, jobs[k], mins[k], "NO RATE"
    }
  }
  if (dlc_jobs > 0)
    printf "%-34s %8d %14s %16.1f\n", "Docker Layer Caching", dlc_jobs, "", dlc_credits
  printf "%-34s %8s %14s %16s\n", "----------------------------------", "--------", "--------------", "----------------"
  printf "%-34s %8d %14.2f %16.1f\n\n", "TOTAL", counted, total_minutes, compute + dlc_credits

  if (length(unmapped) > 0) {
    printf "NOT PRICED — no Cloud rate is known for these, so they are EXCLUDED from\n"
    printf "the total. Map each one before relying on this forecast:\n"
    for (k in unmapped) printf "  %s\n", k
    printf "\n"
  }
  if (skip_nostart > 0)
    printf "Excluded %d build(s) that never started — these bill nothing.\n", skip_nostart
  if (skip_zero > 0)
    printf "Excluded %d build(s) with no recorded duration.\n", skip_zero
  if (skip_huge > 0)
    printf "Excluded %d build(s) with an implausible duration (>24h) despite starting.\n", skip_huge

  printf "\nNOT INCLUDED:\n"
  printf "  Users    25,000 credits/user/month (Performance) or 40,000 (Scale)\n"
  printf "  Storage  420 credits/GB-month above the plan allowance\n"
  printf "  Egress   420 credits/GB, and only for traffic to self-hosted runners\n"
  printf "  IP ranges 450 credits/GB\n"
  printf "\nThis is a forecast. Credits are calculated as duration x published\n"
  printf "credits-per-minute rate, not read from a billing system, and may differ from\n"
  printf "actual Cloud billing.\n"
}' "$BUILDS"

[[ -n "$OUT_DIR" ]] && echo "" && echo "Per-build detail: $OUT_DIR/builds.tsv"
exit 0
