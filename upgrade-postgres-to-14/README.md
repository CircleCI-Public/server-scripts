# CircleCI Server: Postgres 12 → 14 upgrade script

NOTE: This script is intended only for server versions 4.9 and after. 

`upgrade-postgres-to-14.sh` automates the on-disk PostgreSQL major-version upgrade inside your CircleCI Server installation. It renders and applies a one-shot Kubernetes Job that runs `pg_upgrade --link` against your existing Postgres PVC, then prints the helm values block to update and the `helm upgrade` command to run.

The full upgrade procedure — including platform-specific guidance on snapshots, rollback, and recovery — is documented separately at **docs.circleci.com** (CircleCI Server upgrade guide). This README focuses on operating the script and the end-to-end flow at a high level.

## What the script does

- Discovers your PVC name, postgres password secret, and the source-cluster encoding/locale. Every value is overridable.
- Verifies that your application-layer deployments are scaled to 0 before doing anything.
- If the postgres StatefulSet is running, captures encoding/locale from the live cluster and **scales postgres to 0** automatically, then waits for the underlying volume to detach.
- If postgres is already at 0 and you did not supply all three `--initdb-*` flags, scales postgres back to 1 briefly to read the locale from `template1`, then returns it to 0. If postgres won't come back up the script hard-fails with a remediation message — see [Auto-discovery behavior](#auto-discovery-behavior).
- Renders a `pg_upgrade` Job manifest, applies it, and streams the Job's logs.
- Verifies completion by waiting for the Job's `Complete` condition.
- On success, prints the helm values block to paste into your CircleCI Server values file and the exact `helm upgrade` command to run.

## What the script does NOT do

- **It does not take backups.** Snapshotting the PVC or pre-provisioning a PVC clone is your responsibility and platform-specific (CSI VolumeSnapshot, your cloud provider's snapshot CLI, Velero, etc.). The script assumes you have a known-good restore path before you invoke it.
- **It does not scale your application layer.** You scale `layer=application` deployments to 0 before invoking the script. The script verifies this and refuses to proceed otherwise. (It does scale the postgres StatefulSet itself — see above.)
- **It does not run `helm upgrade`.** That step is yours — the script tells you exactly what to run. The `helm upgrade` afterward restores replicas to their correct counts for both postgres and your application layer.

## End-to-end upgrade procedure

1. **Pre-flight.**
   - Confirm your cluster can pull the target `server-postgres:14.22.x` image. By default the script pulls from CircleCI's ACR (`cciserver.azurecr.io`); use `--dockerhub` if you pull from Docker Hub.
   - Decide on a rollback strategy: a point-in-time snapshot of the postgres PVC, or a pre-provisioned PVC clone, or both. *How* you take either depends on your platform — see the detailed upgrade guide on docs.circleci.com.
   - Source-cluster encoding and locale: in the standard flow, the script captures these for you (it queries `template1` while postgres is still running, then scales postgres to 0 itself). You don't need to query manually. If you'd like to verify ahead of time:
     ```
     PGP=$(kubectl -n <ns> get secret <secret-name> \
       -o jsonpath='{.data.postgres-password}' | base64 -d)
     kubectl -n <ns> exec postgresql-0 -- env PGPASSWORD="$PGP" \
       psql -U postgres -tAc \
       "SELECT pg_encoding_to_char(encoding), datcollate, datctype \
        FROM pg_database WHERE datname='template1'"
     ```
     The script's built-in defaults are `UTF8` / `C.UTF-8` / `C.UTF-8`. Common alternative locales are `en_US.UTF-8` for `LC_COLLATE` / `LC_CTYPE` on some Bitnami builds. You don't have to capture these manually — if postgres is at 0 when the script starts, it bounces postgres back up briefly to read the locale itself. But if you'd rather skip the bounce, pass the values to the script:
     ```
     ./upgrade-postgres-to-14.sh -n <ns> \
       --initdb-encoding <encoding> \
       --initdb-lc-collate <lc_collate> \
       --initdb-lc-ctype <lc_ctype>
     ```
     A locale or encoding mismatch causes `pg_upgrade` to abort partway through its consistency checks with an error naming the offending database and value.
   - Plan a maintenance window. Total downtime depends on your database size, storage performance, the number of databases and extensions, and post-upgrade `VACUUM ANALYZE` time. We recommend at least 30-60 minutes.

2. **Take a backup.** Snapshot the PVC, or pre-provision a clone PVC, or both. The remaining steps assume you can restore from one of these if anything goes wrong.

3. **Quiesce the application layer.** Scale your application deployments to 0. Leave the postgres StatefulSet alone — the script will scale it down itself after capturing the live cluster's encoding/locale:
   ```
   kubectl -n <ns> scale deploy -l layer=application --replicas=0
   ```
   The script refuses to proceed if any `layer=application` deployment still has replicas > 0.

4. **Run the upgrade.** With the application layer quiesced:
   ```
   ./upgrade-postgres-to-14.sh -n <namespace>
   ```
   See [Flags](#flags) for overrides. The script will:
   - Query the live postgres pod for encoding/locale.
   - Prompt to scale the postgres StatefulSet to 0, then wait for the underlying volume to detach (the cloud-side detach round-trip typically takes 30–90 seconds).
   - Apply the `pg_upgrade` Job and stream its logs.
   - Exit 0 once `pg_upgrade` reports `Upgrade Complete` and the new PG14 cluster is in place at `/bitnami/postgresql/data`.

   If you scaled postgres down ahead of time, the script will bounce it back to 1 briefly to read the locale before applying the Job — no manual capture needed. (Pass `--initdb-encoding` / `--initdb-lc-collate` / `--initdb-lc-ctype` if you want to skip the bounce.)

5. **Update your helm values.** On success, the script prints the exact `postgresql:` block to paste into your CircleCI Server values file. The change is in the `postgresql.image` registry/repository/tag — for the default (ACR) run, the diff against the previous PG12 pin looks like:

   ```diff
    postgresql:
      image:
        registry: cciserver.azurecr.io
        repository: server-postgres
        tag: 14.22.4094-4922444
   ```

   If you ran the script with `--dockerhub`, `registry: docker.io` stays — only the `tag` changes.

6. **Roll forward.** Run `helm upgrade` against your CircleCI Server release. This upgrades the chart, deploys the new postgres image, and restores correct replica counts for postgres and your application workloads — you don't need a separate scale-up:
   ```
   helm upgrade circleci-server \
     oci://cciserver.azurecr.io/circleci-server \
     --version <server-version> \
     -f <path-to-your-values-file>
   ```
   The new postgres pod mounts the upgraded data directory and starts on PG14.

7. **Validate.**
   ```
   PGP=$(kubectl -n <ns> get secret <secret-name> \
     -o jsonpath='{.data.postgres-password}' | base64 -d)
   kubectl -n <ns> exec -it postgresql-0 -- \
     env PGPASSWORD="$PGP" psql -U postgres -c 'SELECT version();'
   kubectl -n <ns> exec -it postgresql-0 -- \
     env PGPASSWORD="$PGP" vacuumdb -U postgres --all --analyze-in-stages
   ```
   `pg_upgrade` does NOT carry optimizer statistics across — `vacuumdb --analyze-in-stages` rebuilds them and keeps query plans sane. Smoke-test your CircleCI install (log in, trigger a workflow) and watch the postgres logs for any startup warnings.

8. **Clean up.** After at least 24 hours of healthy operation on PG14 (the upgrade Job auto-deletes 24h after completion via `ttlSecondsAfterFinished`, so no manual Job deletion is needed):
   - Inside the postgres pod, remove the old data directory left behind by `pg_upgrade`:
     ```
     kubectl -n <ns> exec -it postgresql-0 -- bash
     # then, inside the pod:
     bash /bitnami/postgresql/upgrade-logs/delete_old_cluster.sh
     ```
   - Delete your snapshot or pre-provisioned clone PVC if you no longer need them.

## Quick start

```bash
# Standard install: everything auto-discovered, ACR by default
./upgrade-postgres-to-14.sh -n circleci-server

# Pull server-postgres from Docker Hub instead of ACR
./upgrade-postgres-to-14.sh -n circleci-server --dockerhub

# Use a newer PG14 tag than the script's default
./upgrade-postgres-to-14.sh -n circleci-server -t 14.22.5000-newsha

# Preview the rendered Job manifest without applying
./upgrade-postgres-to-14.sh -n circleci-server --dry-run

# Use a custom image pull secret (instead of the default 'regcred')
./upgrade-postgres-to-14.sh -n circleci-server --image-pull-secret my-acr-secret

# Omit imagePullSecrets entirely (cluster-wide pull credentials already configured)
./upgrade-postgres-to-14.sh -n circleci-server --image-pull-secret ""

# Fully explicit, no confirmation prompts
./upgrade-postgres-to-14.sh -n circleci-server \
  --pvc-name data-postgresql-0 --secret-name postgresql \
  --initdb-lc-collate en_US.UTF-8 --initdb-lc-ctype en_US.UTF-8 \
  -y
```

## Flags

| Flag | Default | Purpose |
|---|---|---|
| `-n, --namespace NS` | *(required)* | Namespace where your postgres StatefulSet runs. |
| `-t, --pg14-tag TAG` | `14.22.4094-4922444` | server-postgres image tag to upgrade to. |
| `--pvc-name NAME` | auto-discovered | Source PVC. Defaults to whatever has `app.kubernetes.io/name=postgresql` in your namespace. |
| `--secret-name NAME` | auto-discovered | Secret holding the postgres superuser password. |
| `--secret-key KEY` | `postgres-password` | Key within that secret. |
| `--initdb-encoding ENC` | discovered, else `UTF8` | New cluster encoding. |
| `--initdb-lc-collate LOC` | discovered, else `C.UTF-8` | New cluster `LC_COLLATE`. Must match source. |
| `--initdb-lc-ctype LOC` | discovered, else `C.UTF-8` | New cluster `LC_CTYPE`. Must match source. |
| `--dockerhub` | off | Pull both the `server-postgres` image (`circleci/server-postgres`) and the `pg_upgrade` Job image (`circleci/server-postgres-upgrade:12-14`) from Docker Hub instead of ACR. |
| `--acr-path PATH` | `cciserver.azurecr.io/server-postgres` | Override the ACR repository path. |
| `--upgrade-job-image IMG` | `cciserver.azurecr.io/server-postgres-upgrade:12-14` (ACR), or `circleci/server-postgres-upgrade:12-14` with `--dockerhub` | Image used by the `pg_upgrade` Job itself. |
| `--image-pull-secret NAME` | `regcred` | `imagePullSecrets` entry added to the upgrade Job pod spec. Pass an empty string (`--image-pull-secret ""`) to omit `imagePullSecrets` entirely (e.g. if your cluster already has cluster-wide pull credentials). |
| `-y, --yes` | off | Skip confirmation prompts. |
| `--dry-run` | off | Render the Job manifest and exit without applying. |
| `-h, --help` | — | Show usage. |

## Prerequisites

- `kubectl` configured for the target cluster (verify with `kubectl config current-context`).
- A standard CircleCI Server internal installation of `postgresql`.
- Network reachability from your cluster to the registry hosting the PG14 image (ACR by default), with pull credentials available. The script adds `imagePullSecrets: [{name: regcred}]` to the upgrade Job by default; use `--image-pull-secret` to specify a different secret name, or `--image-pull-secret ""` to omit it if your cluster has cluster-wide pull credentials.
- Network reachability from your cluster to the registry hosting the `pg_upgrade` Job image — by default `cciserver.azurecr.io/server-postgres-upgrade:12-14` from ACR, or `circleci/server-postgres-upgrade:12-14` from Docker Hub with `--dockerhub`. If your cluster can't reach either, mirror that image to your own registry and pass it via `--upgrade-job-image`.
- Your application-layer workloads (`layer=application`, Deployments and StatefulSets) scaled to 0 before invocation — the script verifies this and refuses to proceed otherwise. The postgres StatefulSet does *not* need to be scaled in advance; the script handles that.
- The target namespace does not enforce Pod Security `restricted` admission. The Job needs to run as root (UID 0) for a chown step that bridges the upgrade image's UID 999 and the chart's UID 1001. If your namespace has `pod-security.kubernetes.io/enforce=restricted`, the script will fail pre-flight with a remediation message (temporarily relax the label to `baseline`, run the upgrade, restore).

## Auto-discovery behavior

The script reads the cluster to fill in placeholder values, so a typical invocation needs only `--namespace`.

- **PVC name and secret name** are looked up via the `app.kubernetes.io/name=postgresql` label.
- **Encoding and locale** are queried from the live postgres pod's `template1` catalog when the script starts. Discovery happens *before* the script scales postgres down, so it succeeds in the standard flow. If postgres is already at 0 when the script starts (e.g. you scaled it down yourself), the script briefly scales it back to 1 just to read the locale, then returns it to 0 — so you don't need to remember to pass `--initdb-*` flags. If postgres won't come back up within 5 minutes, or `psql` against `template1` fails, the script hard-fails with a remediation message; re-run after fixing postgres, or pass `--initdb-encoding` / `--initdb-lc-collate` / `--initdb-lc-ctype` explicitly to skip discovery entirely.

In the rarer case where postgres is running but the live `psql` query fails (e.g. wrong secret key), the script warns and falls back to its built-in defaults (`UTF8` / `C.UTF-8` / `C.UTF-8`). A mismatch with the source cluster's actual settings causes `pg_upgrade` to abort partway through its consistency checks — see [Pre-flight](#end-to-end-upgrade-procedure) (step 1) for how to override.

## Image source defaults

- **server-postgres image** defaults to `cciserver.azurecr.io/server-postgres:<tag>` from CircleCI's ACR. Use `--dockerhub` to pull `circleci/server-postgres:<tag>` from Docker Hub instead, or `--acr-path` to override the ACR path.
- **pg_upgrade utility image** defaults to `cciserver.azurecr.io/server-postgres-upgrade:12-14` from CircleCI's ACR. Use `--dockerhub` to pull `circleci/server-postgres-upgrade:12-14` from Docker Hub instead, or `--upgrade-job-image` to point at any other registry (e.g. a mirror).
- **Image pull secret** — the upgrade Job pod spec includes `imagePullSecrets: [{name: regcred}]` by default. Override with `--image-pull-secret <name>` to use a different secret, or pass `--image-pull-secret ""` to omit the field entirely.

## What success looks like

The script prints the next-step block at the end of a successful run:

```
═══════════════════════════════════════════════════════════════════════════
NEXT STEPS
═══════════════════════════════════════════════════════════════════════════

1. UPDATE your helm values file. Replace the postgresql block with:

  postgresql:
    image:
      registry: cciserver.azurecr.io
      repository: server-postgres
      tag: 14.22.4094-4922444

2. RUN helm upgrade ...
3. VALIDATE ...
4. AFTER ≥24h of healthy operation, clean up ...
═══════════════════════════════════════════════════════════════════════════
```

After updating the values file, run `helm upgrade circleci-server oci://cciserver.azurecr.io/circleci-server --version <server-version> -f <path-to-your-values-file>` to roll forward. This single command rolls the chart, applies the new postgres image, and restores correct replica counts for postgres and your application workloads — no separate scale-up needed.

## Troubleshooting

### Re-running after a failed Job

The Job's first step refuses to re-run if `data-12`, `data-14`, or `data-12.preupgrade` exist on the PVC. To recover, run a one-shot pod that mounts the PVC and resets the state:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pg-upgrade-cleanup
  namespace: <your-namespace>
spec:
  restartPolicy: Never
  securityContext:
    runAsUser: 0
    runAsGroup: 0
  containers:
    - name: cleanup
      image: busybox:latest
      command:
        - sh
        - -c
        - |
          set -ex
          cd /bitnami/postgresql
          if [ -d data-12 ] && [ ! -e data ]; then mv data-12 data; fi
          rm -rf data-14 upgrade-logs
          chown -R 1001:1001 data
      volumeMounts:
        - name: data
          mountPath: /bitnami/postgresql
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: <your-postgres-pvc>
```

Apply, wait for it to reach phase `Succeeded`, delete it, then re-run `upgrade-postgres-to-14.sh`.

### Common pg_upgrade failures

- **Locale mismatch** — `lc_collate values for database "<name>" do not match` aborts the consistency checks. Re-run with `--initdb-lc-collate` / `--initdb-lc-ctype` set to the source cluster's actual values.
- **Missing extension build** — if your PG12 databases use extensions (e.g. `pg_stat_statements`, `pgcrypto`, `uuid-ossp`), the target PG14 image must include them. Catalog all extensions per database during pre-flight:
  ```
  for db in $(kubectl -n <ns> exec postgresql-0 -- env PGPASSWORD="$PGP" \
      psql -U postgres -tAc \
      "SELECT datname FROM pg_database WHERE datistemplate=false AND datname!='postgres'"); do
    echo "=== $db ==="
    kubectl -n <ns> exec postgresql-0 -- env PGPASSWORD="$PGP" \
      psql -U postgres -d "$db" -c "SELECT extname, extversion FROM pg_extension"
  done
  ```
- **Authentication failure connecting to source cluster** — confirm `POSTGRES_SECRET_NAME` and `POSTGRES_SECRET_KEY` are correct by running:
  ```
  PGP=$(kubectl -n <ns> get secret <secret-name> \
    -o jsonpath='{.data.<secret-key>}' | base64 -d)
  kubectl -n <ns> exec postgresql-0 -- env PGPASSWORD="$PGP" \
    psql -U postgres -c 'SELECT 1'
  ```
  *before* quiescing the cluster.

For anything outside these common cases — including rollback procedures — refer to the CircleCI Server upgrade guide on docs.circleci.com.

## Where to go next

The detailed customer-facing upgrade documentation (with platform-specific snapshot and PVC clone procedures, rollback playbooks, and the full troubleshooting reference) is on **docs.circleci.com** under the CircleCI Server upgrade guide.
