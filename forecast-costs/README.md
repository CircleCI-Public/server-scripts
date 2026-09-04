# CircleCI Server compute cost forecast

`check-usage.sh` estimates CircleCI Cloud compute credits for a CircleCI Server install by reading its build records over the Server HTTP API and pricing each job against published Cloud credit rates.

This is a **forecast / estimate**, not a billing invoice.

## Requirements

| Tool | Why |
|------|-----|
| **bash** | Script shell |
| **curl** | Talk to the Server API |
| **jq** | Parse API responses |
| **awk** | Aggregate and price |
| API token | An account with **admin scope** on the install — the build listing endpoint is admin-only |

No `kubectl`, no `psql`, no port-forward and no database credentials. The script only issues HTTP `GET` requests, so it changes nothing in the installation.

### Getting a token

Create one in your Server UI under **User Settings → Personal API Tokens**, then export it. Do not hardcode it.

```bash
export CIRCLE_SERVER_TOKEN='<your-token>'
```

## Usage

```bash
./check-usage.sh -u <server-url> [-d <days>] [-g <gen>] [-m <max-builds>] [-o <dir>]
```

Make the script executable once if needed:

```bash
chmod +x check-usage.sh
```

### Flags

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `-u` | Yes | — | Base URL of the Server install, e.g. `https://circleci.example.com` |
| `-d` | No | `30` | Look-back window in days |
| `-g` | No | `gen1` | Cloud resource-class generation to price against: `gen1` or `gen2` |
| `-m` | No | `2000` | Safety cap on how many builds to examine |
| `-o` | No | — | Write per-build detail to `<dir>/builds.tsv` |
| `-h` | No | — | Show help |

### Examples

**Default:** last 30 days, gen1 rates.

```bash
./check-usage.sh -u https://circleci.example.com
```

**Wider window**, which is usually more representative:

```bash
./check-usage.sh -u https://circleci.example.com -d 90
```

**Keep the per-build data** to pivot yourself:

```bash
./check-usage.sh -u https://circleci.example.com -d 90 -o ./forecast
```

## Output

One row per `executor:class` actually observed, plus Docker Layer Caching and a total:

```
EXECUTOR : CLASS                       JOBS        MINUTES          CREDITS
---------------------------------- -------- -------------- ----------------
linux:xlarge                             17          29.13           2913.2
runner:myorg/my-runner-class              9          18.27              0.0
remotedocker:large                       10           1.16             23.3
docker:medium                            25           7.39             73.9
Docker Layer Caching                     10                          2000.0
---------------------------------- -------- -------------- ----------------
TOTAL                                   129         225.10           6414.2
```

Results are reported in **credits**. Applying a credit rate is left to the reader, since it depends on plan and contract.

## How it works

1. Pages through `GET /api/v1/admin/recent-builds` (newest first, via `offset`) until a whole page falls outside the window.
2. For each build in the window, reads `GET /api/v1.1/project/{vcs}/{org}/{repo}/{build_num}`.
3. Groups by executor and resource class, multiplies minutes by the published credits-per-minute rate, and adds Docker Layer Caching at 200 credits per job.

### Why the per-build call is necessary

The resource class and executor type are only on the **per-build detail** response. The listing endpoint returns `"picard": null`, which makes them look unavailable. That detail response carries:

```json
"picard": {
  "executor": "docker",
  "resource_class": { "class": "medium", "cpu": 2, "ram": 4096 }
},
"parallel": 1,
"build_time_millis": 3022
```

`.picard.executor` distinguishes `docker`, `linux` (machine), `remotedocker` and `runner`, which matters because they price off different tables — Linux VM `xlarge` is 100 credits/min against Docker `xlarge`'s 40. Because `cpu` and `ram` come back too, the mapping onto Cloud's named tiers can be verified rather than assumed.

The two endpoints also disagree on duration: the listing value includes queued time, which Cloud does not bill, so the detail value is the correct basis.

## Notes and caveats

- **Builds that never started are excluded** and counted separately — they consumed no compute. Such builds report `build_time_millis = 9223372036854` (`Long.MAX_VALUE` ms) because the duration derives from a null `start_time`; the script tests `start_time` rather than the magnitude. A genuinely **failed** build that *did* run is billable and **is** counted.
- **Unpriced resource classes are reported, never silently dropped.** If an `executor:class` has no known Cloud rate it appears as `NO RATE` and is excluded from the total, with a warning. Operator-defined classes can produce these.
- **Self-hosted runner jobs incur no per-minute compute credits** on Cloud and are priced at zero.
- **Remote Docker is billed as a VM**, not a container: `setup_remote_docker` is provisioned as a Linux VM and prices off the VM table.
- **`gen1` is the default** because Server supports only gen1 x86 Docker classes, whose CPU/RAM match Cloud gen1 exactly, making it a like-for-like comparison. `-g gen2` is not uniformly more expensive: Docker gen2 costs ~20% more per minute, while Linux VM gen2 is *cheaper* at `xlarge` and above (72 vs 100 credits/min) and dearer at `medium`/`large`, so the net effect depends on your mix. gen2 also runs faster, so applying gen2 rates to gen1-measured durations overstates the classes that cost more.
- **Parallelism multiplies billable minutes**: N executors for M minutes bills N×M.
- **Not included**, because build records do not carry them: users (25,000 credits/user/month on Performance, 40,000 on Scale), storage (420 credits/GB-month above allowance), network egress to self-hosted runners (420 credits/GB), and IP ranges (450 credits/GB).
- Credit rates come from the [CircleCI price list](https://circleci.com/pricing/price-list/) and change over time. Re-verify before relying on a figure.
- Runtime is roughly one API request per build in the window. Raise `-m` for large installs, and expect a few minutes for several hundred builds.
