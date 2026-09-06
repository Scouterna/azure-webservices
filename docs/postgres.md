# PostgreSQL on this cluster

**One shared server absorbs many small project databases.** A project gets a
database and a role on it, not its own Postgres instance.

## Why shared

This cluster's expected shape is many small projects — several used by a handful
of people, some for a single season. A dedicated Postgres per project reserves
far more than such a workload uses: on a single node, ten projects with dev+prod
instances would request ~3 CPU before any application runs. One shared server
carries the same databases at a fraction of that.

The trade is isolation. A shared server means shared memory settings, one major
version, and one restore affecting every database on it. That is acceptable for
small projects and **not** acceptable for a heavy one — hence the escape hatch
below.

The alternative we did **not** choose is a managed Azure PostgreSQL with
hand-built DSNs (the J26 model). It works, but every database needs an infra
admin to be available, and this infra team is a small group of volunteers. Here,
adding a database is a commit.

## Layout

```
postgres/                              ← infra-owned namespace
  Cluster shared                       one server, one backup policy
  ObjectStore shared-store             → cnpg-shared container
  Database     <project>-dev/-prod     one per project ENVIRONMENT
  DatabaseRole <project>-dev/-prod     separate role per environment
  Secret postgres-<project>-<env>-role role password, from Key Vault via ESO

<project>-dev/  <project>-prod/        ← project's own namespaces
  Secret <project>-db                  host/port/dbname/username/password/uri
```

**dev + prod is the default**, matching the namespace layout in
[onboarding.md](onboarding.md) §A2. Both templates carry both environments, so a
single `PROJECT` substitution produces every name consistently. Names carry the
environment suffix because all databases share one server and must be unique
across it — and each environment gets its **own role**, so a leaked dev
credential cannot reach prod data.

**One environment only:** delete the prod block from both templates and drop the
`-dev` suffix in what remains (one Key Vault password instead of two).
**Adding staging:** copy a block in each template, change the suffix, and add its
Key Vault password.

Projects connect to `shared-rw.postgres.svc.cluster.local:5432`.

**Why `Database`/`DatabaseRole` are not in the project's namespace:** CNPG
resolves `spec.cluster` by **name only** — there is no namespace field — so both
must sit beside the `Cluster` they belong to. Keeping them infra-owned is also
the safer boundary: a project cannot create objects next to another project's
database.

## Adding a database

1. Put a generated password in Key Vault **per environment** — dev and prod get
   separate roles, so a leaked dev credential cannot reach prod data:
   ```bash
   for env in dev prod; do
     az keyvault secret set --vault-name kv-scouterna-webservices \
       --name "postgres-<project>-$env-password" \
       --value "$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)" >/dev/null
   done
   ```
2. Copy `k8s/infra-manifest/postgres/databases/_template.yaml.example` to
   `<project>.yaml`, replace `PROJECT`, commit. The `postgres-databases` app
   applies it.
3. In the project's own directory, activate
   `infra/database.yaml.example` → `infra/database.yaml` (see
   [onboarding.md](onboarding.md)). That materializes the connection Secret into
   the project's namespace.
4. Verify:
   ```bash
   kubectl get database,databaserole -n postgres
   kubectl get externalsecret -n <project>-prod
   ```

`prune` is **disabled** on the `postgres-databases` app and
`databaseReclaimPolicy: retain` is set, so deleting the file does not drop the
data. Retiring a database is deliberate: set `ensure: absent` after taking a
final backup.

## What isolation you actually get

Each database is owned by its own role, and roles cannot read each other's
tables — verified on the test cluster: a role from one environment gets
`permission denied for table` against another's data, and `permission denied for
schema public` if it tries to create anything.

**Any role can still open a connection to any database on the server.** Postgres
grants `CONNECT` to `PUBLIC` by default, so `psql -d someone-elses-db -c 'select 1'`
succeeds. That is a login boundary, not a data boundary — nothing is readable
through it — but it means "can connect" is not a useful isolation test. Test with
real tables.

If a project needs a database no other role may even connect to, revoke it
explicitly:

```sql
REVOKE CONNECT ON DATABASE "<db>" FROM PUBLIC;
GRANT  CONNECT ON DATABASE "<db>" TO "<role>";
```

Projects that need a stronger guarantee than this should get their own instance.

## When a project should get its own instance

Give a project its own CNPG `Cluster`, in its own namespace, when it needs:

- sustained load that would disturb other databases,
- a different major version or an extension the shared server does not carry,
- an independent restore/PITR timeline, or
- data that must not share a server for policy reasons.

The `project-infra` AppProject permits `postgresql.cnpg.io` and `PodMonitor` in a
project namespace exactly for this. Size it, give it its own `ObjectStore`
pointing at a per-project container, and add a `PodMonitor` labelled
`release: kps` so it is monitored like the shared one.

## Capacity

The shared server requests 200m CPU / 1Gi and is sized for the sum of many small
databases, not one workload. Watch it as projects land — `max_connections` is
200, and the CloudNativePG Grafana dashboard shows connections, transactions,
replication lag and cache hit ratio. Raising the request, the storage tier, or
adding a node is a values change; splitting a heavy tenant out to its own
instance is usually the better answer.

## Backups, and restoring from them

Every database on the shared server is covered by one backup path: a **daily base
backup** at 02:30 plus **continuous WAL archiving**, written by the Barman Cloud
plugin to the `cnpg-shared` container of the durable backup storage account. That
combination is what makes **point-in-time recovery** possible — recovery to any
moment inside the retention window, not just to the nightly snapshot.

Retention is **90 days** (`ObjectStore.spec.retentionPolicy`). It is sized to how
late a problem is typically noticed rather than to an RPO — a dropped table is
often found weeks later, and a 30-day window can expire first. It matches the
`weekly-full` Velero TTL for the same reason.

Unlike PersistentVolume backups, these are **real objects in blob storage**, so
they survive losing the cluster entirely.

> **`serverName` must change on a rebuild.** Barman stores under
> `<destinationPath>/<serverName>/`, and the backup account deliberately outlives
> the cluster. Rebuilding with the same `serverName` points a **new** database at
> the **old** database's backup path — different system identifier, same
> location. Bump `serverName` (e.g. `shared-1` → `shared-2`) in
> `k8s/infra-manifest/postgres/cluster.yaml` whenever you rebuild against a
> storage account that already holds backups.

### Verify the backups exist

```bash
kubectl get backup -n postgres                    # CNPG's own Backup objects
kubectl get cluster -n postgres shared \
  -o jsonpath='{.status.lastSuccessfulBackup}{"\n"}'
```

`lastSuccessfulBackup` is the field that matters. A `Cluster` reporting healthy
with an empty or stale value is backing up nothing.

### Restore drill — do this once, on a test cluster

A backup that has never been restored is a hypothesis. Run this end to end before
relying on it; it costs a few minutes and is the only thing that proves the path.

1. **Write a known row** into a project database:
   ```bash
   kubectl exec -n postgres shared-1 -c postgres -- \
     psql -d <database> -c \
     "create table restore_drill(id int, note text);
      insert into restore_drill values (1, 'written before the drill');"
   ```

2. **Take a backup on demand** rather than waiting for 02:30, and note the time:
   ```bash
   date -u +%Y-%m-%dT%H:%M:%SZ            # remember this — the recovery target
   kubectl apply -f - <<'EOF'
   apiVersion: postgresql.cnpg.io/v1
   kind: Backup
   metadata:
     name: restore-drill
     namespace: postgres
   spec:
     cluster:
       name: shared
     method: plugin
     pluginConfiguration:
       name: barman-cloud.cloudnative-pg.io
   EOF
   kubectl wait --for=jsonpath='{.status.phase}'=completed \
     backup/restore-drill -n postgres --timeout=10m
   ```

3. **Destroy something recoverable** — drop the table, so success is unambiguous:
   ```bash
   kubectl exec -n postgres shared-1 -c postgres -- \
     psql -d <database> -c "drop table restore_drill;"
   ```

4. **Recover into a SECOND cluster.** Never recover in place during a drill: a
   failed in-place recovery costs you the live database as well. CNPG restores by
   creating a new `Cluster` that bootstraps from the object store:
   ```yaml
   apiVersion: postgresql.cnpg.io/v1
   kind: Cluster
   metadata:
     name: shared-restore
     namespace: postgres
   spec:
     instances: 1
     imageName: ghcr.io/cloudnative-pg/postgresql:17
     storage:
       size: 32Gi
       storageClass: disk-standardssd
     bootstrap:
       recovery:
         source: shared-origin
         # Omit recoveryTarget to recover to the latest available WAL.
         recoveryTarget:
           targetTime: "<the timestamp from step 2>"
     externalClusters:
       - name: shared-origin
         plugin:
           name: barman-cloud.cloudnative-pg.io
           parameters:
             barmanObjectName: shared-store
             serverName: shared-1
   ```
   The `serverName` here must match the one the backup was written under — that
   is the whole reason it is set explicitly.

5. **Prove it came back:**
   ```bash
   kubectl exec -n postgres shared-restore-1 -c postgres -- \
     psql -d <database> -c "select * from restore_drill;"
   ```
   The row from step 1 must be there. If it is, the backup path works — base
   backup, WAL archiving, credentials, and the object store all.

6. **Clean up** so the drill leaves nothing behind:
   ```bash
   kubectl delete cluster -n postgres shared-restore
   kubectl delete backup -n postgres restore-drill
   ```

**What a failure here would mean.** The most likely causes, in order: the
storage-account key in `backup-storage-key` is wrong or rotated; `serverName`
does not match what the backup was written under; or the `cnpg-shared` container
does not exist (it is created by `infra/backup-storage.bicep`, not by CNPG).
`kubectl logs -n postgres shared-1 -c plugin-barman-cloud` shows which.

### What is not covered

- **A dropped table found after 90 days.** Outside the window there is nothing to
  recover from.
- **Backup failure is only partly alerted.** `PostgresWALArchivingFailing` fires
  when WAL archiving breaks — the continuous half. A failing *base* backup has no
  alert of its own; `lastSuccessfulBackup` going stale is the signal, and nothing
  watches it yet.
- **No alert reaches anyone until Alertmanager has its Slack webhook**
  (`install.md` §5c). Until that secret exists, every alert above fires into a
  pod that cannot start.
