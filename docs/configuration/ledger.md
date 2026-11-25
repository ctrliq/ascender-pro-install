# Ledger: PostgreSQL, Scheduler, MCP and the MariaDB Migration

This guide covers what the installer deploys for Ledger, the storage it needs, and how an
existing Ledger that still runs on MariaDB is moved to PostgreSQL.

- [What gets deployed](#what-gets-deployed)
- [Database](#database)
- [Scheduler data volume](#scheduler-data-volume)
- [MCP server](#mcp-server)
- [Upgrading an install that runs MariaDB](#upgrading-an-install-that-runs-mariadb)
- [Rolling back to MariaDB](#rolling-back-to-mariadb)
- [Migrating an external MariaDB database](#migrating-an-external-mariadb-database)
- [Troubleshooting](#troubleshooting)

## What gets deployed

Everything lives in `LEDGER_NAMESPACE` (default `ledger`). The manifest is written to
`tmp_dir` as `ledger_deployment_<k8s_platform>.yaml.<timestamp>` on every run.

| Object | Kind | Notes |
| ------ | ---- | ----- |
| `web`, `web-svc` | Deployment, Service | Ledger UI and REST API. `ledger_web_replicas` pods. |
| `parser`, `parser` | Deployment, Service | Receives Ascender's job events on port 5000. |
| `scheduler` | Deployment, Service | Advisory downloads and background jobs. Always 1 replica, `Recreate` strategy. The Service carries its internal API (port 8090) inside the namespace for the web pods; every call but `/healthz` needs a token. |
| `mcp` | Deployment, Service | Optional read-only MCP server on port 8085 (`LEDGER_MCP_INSTALL`). |
| `postgres` | StatefulSet, Service | Internal PostgreSQL 18, port 5432. Not deployed for an external database. |
| `postgres-data` | PVC (ReadWriteOnce) | PostgreSQL data, `LEDGER_PVC_SIZE_GB` / `LEDGER_PVC_STORAGE_CLASS`. |
| `ledger-data` | PVC (ReadWriteOnce) | The scheduler's `/app/data`, `LEDGER_DATA_PVC_SIZE_GB` / `LEDGER_DATA_STORAGE_CLASS`. |
| `db-settings`, `db-ledger-password`, `admin-password` | Secrets | Database connection (`config.json`), database password, admin password. |
| `ledger-web-ingress` / `web-route` | Ingress / Route | `LEDGER_HOSTNAME`, per platform as before. |
| `ledger-mcp-ingress` / `mcp-route` | Ingress / Route | Only when `LEDGER_MCP_HOSTNAME` is set. |

The images come from `depot.ciq.com/ascender-pro/ascender-ledger-pro-images`: `ledger-web`,
`ledger-parser`, `ledger-scheduler` and `ledger-mcp`, all at `LEDGER_VERSION`, plus
`LEDGER_POSTGRES_IMAGE` (`quay.io/sclorg/postgresql-18-c9s`, pinned by digest). With
`k8s_container_registry` set, all of them are pulled from that registry by their base name
(`<registry>/postgresql-18-c9s:latest` for PostgreSQL); `create_bundle.yml` pulls and pushes all
five. The old `ledger-db` (MariaDB) image is no longer deployed.

## Database

Ledger runs on PostgreSQL only.

**Internal database (default).** Leave `LEDGER_DB_HOST` unset (or set it to `postgres`; the old
value `db` means the same). The installer deploys the `postgres` StatefulSet and points
`db-settings` at `postgres:5432`. If your configuration still sets `LEDGER_DB_PORT: "3306"`, the
installer uses 5432 anyway and prints a warning. PostgreSQL takes its user and database name
from `db-settings` and its password from `db-ledger-password`; Ledger creates its schema on first
start.

- PostgreSQL runs as UID 26 with `fsGroup: 26`. On OpenShift that security context is left out
  and the pod runs under the `restricted-v2` SCC with a UID from the namespace range, which the
  image supports. (The `ledger-app` service account with the `anyuid`/`privileged` SCCs is only
  used by the web, parser, scheduler and MCP pods.)
- Changing `LEDGER_DB_PASSWORD` restarts PostgreSQL, which sets the new password on start.
  But do not change it on an existing install: Ledger derives the keys that encrypt stored
  settings (SMTP, LDAP, SSO passwords) from it.

**External database.** Set `LEDGER_DB_HOST`, `LEDGER_DB_PORT`, `LEDGER_DB_NAME`,
`LEDGER_DB_USERNAME` and `LEDGER_DB_PASSWORD`. The database must exist and be owned by that user;
PostgreSQL 18 is what Ledger is tested with. `LEDGER_DB_SSLMODE` sets the libpq `sslmode`
(`prefer` when unset; `verify-full` for a server with a trusted certificate). The installer stops
if an external `LEDGER_DB_HOST` is on port 3306: move that data with
[the external migration playbook](#migrating-an-external-mariadb-database) first.

## Scheduler data volume

The advisory data (the downloaded vendor advisories and CVE records, and the staging area of
air-gap bundles) lives in the scheduler's `/app/data`, on the `ledger-data` volume. Only the
scheduler pod mounts it. The web pods reach it through the scheduler's internal API (the
`scheduler` Service, port 8090) for the air-gap Download and Import and for the on-disk figures
on the Advisories page; the two services authenticate each other with a token derived from the
database password they share, so no extra secret is involved.

Because a single pod uses the volume, it is **ReadWriteOnce** and the cluster's default storage
class works everywhere, including k3s `local-path`. The web Deployment can be scaled to any number
of replicas on any nodes without shared storage.

- `LEDGER_DATA_STORAGE_CLASS` picks another class; empty means the cluster default. The installer
  stops when a configured class does not exist.
- `LEDGER_DATA_ACCESS_MODE` accepts `ReadWriteMany` for clusters that prefer it; it is not needed.
- The access mode and storage class of an existing claim cannot be changed. To move to another
  class, scale `scheduler` to 0, delete the `ledger-data` PVC and re-run the installer; the
  advisory data is re-seeded from the scheduler image and re-downloaded.
- The scheduler image carries a snapshot of the advisory data. An init container copies it onto
  the volume once, without overwriting files already there, and leaves a `.installer-seeded`
  marker so it does not copy again. The pod runs as root, so a volume backed by an NFS export
  with `root_squash` must allow those writes (or use `no_root_squash` / an anonymous UID that
  owns the export).

## MCP server

The read-only [MCP](https://modelcontextprotocol.io) server lets AI assistants query Ledger. It
holds no credentials: each client sends its own Ledger credentials, which the server forwards
to the REST API (`LEDGER_API_URL`, the `web-svc` Service). It is on by default
(`LEDGER_MCP_INSTALL: true`) and reachable in the cluster at `http://mcp.<LEDGER_NAMESPACE>:8085`.

Set `LEDGER_MCP_HOSTNAME` to publish it on its own hostname with the same Ingress class, TLS
Secret and annotations as Ledger (a separate ALB on EKS, whose certificate must cover the name; an
edge-terminated Route on OpenShift). Create the DNS record for it yourself. Credentials travel in
the `Authorization` header, so only publish it over HTTPS. Setting `LEDGER_MCP_INSTALL: false`
removes the MCP objects on the next run.

## Upgrading an install that runs MariaDB

Re-running the installer (`setup.sh`, or `playbooks/install_ledger.yml`) on a namespace that
still has the MariaDB Deployment `db` (or the `mysql-data` volume) migrates it:

1. Reads the credentials from the existing `db-settings` Secret, and stops if
   `LEDGER_DB_PASSWORD` differs from the password in use (see the encryption-key note above).
2. Scales `web` and `parser` to 0.
3. Dumps the database with `mysqldump` and copies it to the control node:
   `<tmp_dir>/ledger-mariadb-backup.<timestamp>.sql`. The size and the `Dump completed` trailer
   are checked before going on.
4. Deploys PostgreSQL and waits for it.
5. Runs `ledger-web migrate-from-mariadb` as the Job `ledger-mariadb-migration` against `db:3306`.
   It upgrades the MariaDB schema in place, creates the PostgreSQL schema, copies every table and
   verifies the row counts. The log is printed and saved as
   `<tmp_dir>/ledger-mariadb-migration.<timestamp>.log`.
6. Applies the new manifest: `db-settings` now points at `postgres:5432`, and web, parser,
   scheduler and MCP start.
7. Once Ledger answers with HTTP 200, scales the `db` Deployment to 0 and deletes it and its
   Service. The `mysql-data` volume is **kept** unless `LEDGER_REMOVE_MARIADB_PVC: true`.

Progress is recorded in the ConfigMap `ledger-postgres-migration` (`phase`: `started`, `failed`,
`completed`, plus the backup path). Re-running is safe:

- After a completed migration nothing is copied again; a leftover `db` Deployment is removed.
- After a failed or interrupted copy the migration runs again with `--force`, overwriting the
  partial PostgreSQL data. Until a copy succeeds, `db-settings` and MariaDB are untouched.
- If PostgreSQL already holds data and there is no record, the installer assumes the migration
  was done another way and does not copy. `LEDGER_MIGRATION_FORCE: true` copies anyway,
  overwriting PostgreSQL.
- `LEDGER_SKIP_MARIADB_MIGRATION: true` installs with an empty database and leaves the MariaDB
  objects alone.
- If only the `mysql-data` volume is left (no `db` Deployment) and nothing was migrated, the
  installer stops: bring the `db` Deployment back with the previous installer version first, or
  skip the migration.

Plan for downtime: Ledger is down from step 2 until step 6, which takes about as long as copying
the database twice. Check afterwards:

```bash
kubectl -n ledger get pods
kubectl -n ledger get configmap ledger-postgres-migration -o jsonpath='{.data}'
kubectl -n ledger logs job/ledger-mariadb-migration
```

Delete the old volume once you are satisfied: `kubectl -n ledger delete pvc mysql-data`.

## Rolling back to MariaDB

Roll back with the `mysqldump` backup, because the migration upgrades the MariaDB schema in
place and a Ledger release from before PostgreSQL may not accept the upgraded schema.

1. Remove the PostgreSQL-era objects (this deletes the PostgreSQL data). The MariaDB `db`
   Deployment is still running after a failed migration; it goes first, because a volume
   cannot be deleted while a pod mounts it (it is already gone after a successful one):

   ```bash
   kubectl -n ledger delete deployment db --ignore-not-found --wait
   kubectl -n ledger delete deployment web parser scheduler mcp --ignore-not-found
   kubectl -n ledger delete statefulset postgres
   kubectl -n ledger delete pvc postgres-data mysql-data
   kubectl -n ledger delete configmap ledger-postgres-migration
   kubectl -n ledger delete job ledger-mariadb-migration --ignore-not-found
   ```

2. Check out the installer version you used before (the commit before the PostgreSQL change),
   pin `LEDGER_VERSION` to the Ledger release you ran before, and run that installer. It creates
   a fresh MariaDB `db` Deployment and an empty `mysql-data` volume.
3. Load the backup into it (the dump re-creates every table):

   ```bash
   kubectl -n ledger exec -i deploy/db -- mysql < ascender_install_artifacts/ledger-mariadb-backup.<timestamp>.sql
   kubectl -n ledger rollout restart deployment web parser
   ```

To try the migration again later, simply upgrade the installer and re-run it.

If the migration **failed** (the installer stopped at step 5), nothing points at PostgreSQL yet:
fix the cause shown in the log and re-run the installer. If you would rather go back, the
MariaDB Deployment and volume are still there, but the source schema may already have been
upgraded, so restore the backup as above.

## Migrating an external MariaDB database

For a Ledger whose MariaDB database is not managed by this installer, use
`playbooks/migrate_ledger_external_db.yml`. It runs the same Job in `LEDGER_NAMESPACE`:

```yaml
# custom.config.yml (or pass with -e)
LEDGER_MIGRATE_SOURCE_DB_HOST: mariadb.example.com
LEDGER_MIGRATE_SOURCE_DB_PORT: "3306"
LEDGER_MIGRATE_SOURCE_DB_NAME: ledger
LEDGER_MIGRATE_SOURCE_DB_USERNAME: ledger
LEDGER_MIGRATE_SOURCE_DB_PASSWORD: "..."

# Target: an external PostgreSQL ...
LEDGER_DB_HOST: postgres.example.com
LEDGER_DB_PORT: "5432"
LEDGER_DB_NAME: ledger
LEDGER_DB_USERNAME: ledger
LEDGER_DB_PASSWORD: "..."
# ... or leave LEDGER_DB_HOST unset to fill the internal PostgreSQL StatefulSet
```

```bash
ansible-playbook playbooks/migrate_ledger_external_db.yml
```

- Back up the source first: the migration upgrades its schema in place.
- Stop whatever Ledger still writes to the source. Ledger Deployments in `LEDGER_NAMESPACE` are
  scaled to 0 by the playbook.
- The target must be empty, or set `LEDGER_MIGRATION_FORCE: true`.
- Use the same password for the PostgreSQL user as for the MariaDB user, or re-enter the stored
  SMTP/LDAP/SSO passwords afterwards (the playbook warns when they differ).
- Then run `playbooks/install_ledger.yml` (or `setup.sh`) with the same `LEDGER_DB_*` settings.

### Without access to the cluster

The migration is a command in the `ledger-web` image, so any host with podman (or docker) that
reaches both databases can run it:

```bash
cat > config.json <<'EOF'
{"db_host": "postgres.example.com", "db_port": "5432", "db_name": "ledger",
 "db_username": "ledger", "db_password": "...", "db_sslmode": "prefer"}
EOF
chmod 600 config.json

podman login depot.ciq.com
podman run --rm \
  -v "$PWD/config.json:/run/secrets/db-settings/config.json:ro,Z" \
  -e SOURCE_DB_HOST=mariadb.example.com \
  -e SOURCE_DB_PORT=3306 \
  -e SOURCE_DB_NAME=ledger \
  -e SOURCE_DB_USER=ledger \
  -e SOURCE_DB_PASSWORD='...' \
  depot.ciq.com/ascender-pro/ascender-ledger-pro-images/ledger-web:<LEDGER_VERSION> \
  migrate-from-mariadb
```

The image's entrypoint is `/app/ledger-web`, so `migrate-from-mariadb` is its argument; add
`--force` to overwrite a non-empty target. `config.json` is the target, in the same format as the
`db-settings` Secret. `SOURCE_DB_NAME`, `SOURCE_DB_USER` and `SOURCE_DB_PASSWORD` default to the
target's values when they are the same. The command exits 0 on success.

## Troubleshooting

- **`ledger-data` stays Pending**: the storage class cannot provide a volume in the requested
  access mode (`kubectl -n ledger describe pvc ledger-data`). See
  [Scheduler data volume](#scheduler-data-volume).
- **The scheduler's `seed-data` init container fails** with permission errors: the volume does
  not let root write (NFS `root_squash`).
- **The Advisories page shows no on-disk figures, or Download/Import fail at once**: the web pods
  cannot reach the scheduler's internal API. Check that the `scheduler` pod is Ready
  (`kubectl -n ledger get pods`) and read `kubectl -n ledger logs deploy/web` for `[airgap]`
  lines. "refused the internal API token" means the two Deployments see different database
  passwords; re-run the installer so both use the current `db-settings` Secret.
- **Migration Job failed**: read `<tmp_dir>/ledger-mariadb-migration.<timestamp>.log` or
  `kubectl -n ledger logs job/ledger-mariadb-migration`, fix the cause, re-run the installer.
  `LEDGER_MIGRATION_TIMEOUT` (seconds, default 7200) bounds the Job.
- **"LEDGER_DB_PASSWORD ... is not the database password the running Ledger uses"**: set
  `LEDGER_DB_PASSWORD` to the value shown by
  `kubectl -n ledger get secret db-settings -o jsonpath='{.data.config\.json}' | base64 -d`.
  `config_vars.sh` generates a new random password when the saved one is the sample
  `mydbpassword`, so check this after regenerating `custom.config.yml`.
