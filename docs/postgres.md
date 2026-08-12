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
