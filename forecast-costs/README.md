# CircleCI Server compute cost forecast

`check-usage.sh` estimates CircleCI cloud compute credits for a CircleCI Server install by reading job durations from the `conductor_production` Postgres database and projecting credits across resource classes.

This is a **forecast / estimate**, not a billing invoice.

## Requirements

| Tool | Why |
|------|-----|
| **bash** | Script shell |
| **kubectl** | Discover the Postgres pod/secret and (by default) port-forward to it |
| **psql** | Run the SQL against `conductor_production` |
| Cluster access | Your kubeconfig must be able to talk to the CircleCI Server namespace |

### Installing `psql` locally

You need the PostgreSQL **client** (`psql`), not a full local Postgres server.

**macOS (Homebrew):**

```bash
brew install libpq
brew link --force libpq   # puts psql on your PATH
```

Or install the full package if you prefer:

```bash
brew install postgresql@14
```

**Ubuntu / Debian:**

```bash
sudo apt-get update
sudo apt-get install -y postgresql-client
```

Confirm it works:

```bash
psql --version
```

### Kubernetes access

- `kubectl` configured for the cluster that hosts CircleCI Server
- Permission to `get` pods/secrets in the Server namespace, and to `port-forward` to the Postgres pod (unless you pass `-H` / `-p` to an already-reachable host)

## Usage

```bash
./check-usage.sh -n <namespace> [-d <days>] [-H <pg-host>] [-p <pg-port>]
```

Make the script executable once if needed:

```bash
chmod +x check-usage.sh
```

### Flags

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `-n` | Yes | — | Kubernetes namespace for CircleCI Server |
| `-d` | No | `30` | Look-back window in days |
| `-H` | No | port-forward via kubectl | Postgres host |
| `-p` | No | `5432` (or `15432` when port-forwarding) | Postgres port |

### Examples

**Default:** discover Postgres in the namespace, port-forward, query last 30 days:

```bash
./check-usage.sh -n circleci-server
```

**Custom look-back window:**

```bash
./check-usage.sh -n circleci-server -d 90
```

**Connect to an already-reachable Postgres** (skip port-forward):

```bash
./check-usage.sh -n circleci-server -H 10.0.0.50 -p 5432
```

When `-H` is omitted, the script:

1. Finds the Postgres pod (`app.kubernetes.io/name=postgresql`, then `app=postgresql`)
2. Reads the password from the Postgres secret (`postgres-password` or `postgresql-password`)
3. Port-forwards `localhost:15432` → pod `:5432`
4. Runs `psql` as user `postgres` against database `conductor_production`
5. Tears down the port-forward on exit

If the password cannot be read from the secret, `psql` will prompt for it.

## Output

The script prints a table with one row per estimated resource class (`small` … `2xlarge`) plus a total:

- **estimated_minutes** / **estimated_credits** — per resource class (and summed on the total row)
- **total_jobs** — only on the total row: actual completed jobs in the look-back window (from `job_started_events` / `job_ended_events`)

Credits use CircleCI cloud rates (e.g. medium = 12 credits/minute). Figures are estimates and may differ from actual cloud billing.

## Notes

- Only jobs with both a start and end event, and `ended_at > started_at`, are included.
- The script does not modify the cluster beyond a temporary port-forward (unless you point it at an external host with `-H`).
- The script filename is `check-usage.sh`.
