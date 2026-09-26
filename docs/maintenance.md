# Maintenance plan

The cluster and its common services are pinned to specific versions (in
`infra/aks.bicep` and each `k8s/argocd/infra-apps/*.yaml`). Pinned versions age;
this document is how we keep them current without surprises.

## Principles

- **Pin everything, upgrade deliberately.** Never track `latest`. An upgrade is a
  reviewed change: read the changelog, bump the version in Git, let ArgoCD sync,
  verify. One component at a time.
- **Match cadence to how fast each thing moves.** Some charts release weekly;
  others are stable for months. Don't upgrade on a fixed calendar for its own
  sake — upgrade the fast-movers often, the stable ones rarely.
- **Test before prod.** When there is a dev/test cluster, upgrade there first.
  The whole platform can be rebuilt from Git (see [`docs/install.md`](install.md)), so a bad
  upgrade is recoverable — **as long as every pinned chart and image still exists
  upstream.** Git holds the references, not the artifacts; see
  [Upstream withdrawal](#upstream-withdrawal).

## Cadence by component

Based on each project's real release velocity and blast radius:

| Cadence | Components | Notes |
|---|---|---|
| **Quarterly** (fast-movers) | kube-prometheus-stack, Traefik, ArgoCD, Grafana/Loki/Alloy, the shared Postgres image | Release often; chart-major bumps can change values. Review changelogs. The Postgres image is a pinned CNPG build tag (`imageName` in `k8s/infra-manifest/postgres/cluster.yaml`); bump it after each PostgreSQL minor release (Feb/May/Aug/Nov). |
| **Semi-annual** (stable) | cert-manager, telemetry store, CloudNativePG, Thanos, Headlamp, External Secrets, Gateway API CRDs | Slower cadence, fewer breaking changes. Bump the Gateway API CRDs in step with Traefik (see below). The telemetry store's image is pinned in its values file, not by `targetRevision` (see below). |
| **Semi-annual** (upstream health) | every image the cluster runs | `scripts/check-images-pullable.sh` — see [Upstream withdrawal](#upstream-withdrawal). A pin that no longer exists upstream breaks on the next node upgrade. |
| **Quarterly** (audit health) | the audit log pipeline | Confirm rows are still arriving and the daily cap has not been hit — `install.md` §11. The Azure alerts catch both faster, but this is the check that does not depend on them. |
| **AKS Kubernetes** | the cluster | Patch upgrades are automatic (`autoUpgradeProfile: patch` in the Bicep). **Minor** upgrades (1.36→1.37) are manual, ~3×/year following the K8s release train — do them before the running minor goes out of AKS support. |

## Upgrade-sensitive components (read the changelog first)

Not all bumps are equal. These carry a real risk of breaking changes:

- **External Secrets Operator** — the project moved `0.x → 1.0 → 2.x` in 2025
  (CRD `v1beta1`→`v1`, API changes). We are already on the `2.x` track and our CRs
  use the `v1` API, so ordinary `2.x` bumps are routine. The chart owns its CRDs,
  so an *in-place* upgrade across that old boundary would need the previous CRDs
  removed first — not a concern for a fresh install.
- **Loki** — the OSS chart **changed repository** in March 2026. `grafana/loki`'s
  chart became Grafana **Enterprise** Logs only at `7.0.0`; the OSS chart forked to
  `grafana-community/helm-charts` (from 6.55.0, renumbered to `18.x`). We track the
  community OSS chart. **Never "upgrade" to grafana.github.io `7.x`** — that is a
  different (enterprise) product, not a newer version of what we run.
- **kube-prometheus-stack** — the chart major version changes frequently and can
  rename values / bump CRDs. Diff the values against the new chart's defaults.
- **Traefik** — chart majors (e.g. 39→41) can change the values schema and the
  Traefik minor (v3.6→v3.7). Verify IngressRoutes / middlewares still render.
- **Gateway API CRDs** — installed by the `gateway-api-crds` ArgoCD app (wave 0),
  pinned by `targetRevision` (a git tag). **Pin to Traefik's version, not to the
  latest release.** Traefik is compiled against a specific Gateway API version;
  installing newer CRDs puts the schema ahead of the code that reads it, with no
  benefit. Check before bumping:
  ```bash
  curl -s https://raw.githubusercontent.com/traefik/traefik/v3.7.6/go.mod | grep gateway-api
  # -> sigs.k8s.io/gateway-api v1.5.1   (use the tag matching the chart's appVersion)
  ```
  The app has `prune: false`, so the CRDs (and any Gateways/HTTPRoutes) are never
  deleted by a sync — upgrades apply in place.
- **cert-manager** — generally smooth, but CRD upgrades must be applied (the
  chart handles this with `crds.enabled: true`).
- **Barman Cloud Plugin** — the **only** app that does not upgrade by bumping
  `targetRevision`. Its manifest is vendored at
  `k8s/infra-manifest/barman-cloud-plugin/manifest.yaml`, because the upstream
  `kubernetes/` kustomize base ships **testing images on a moving tag** and no
  path in that git tree yields release images. Upgrading means downloading the
  new release asset over that file — the procedure, and the check that the new
  file really carries release images, are in the README beside it. The file also
  contains the `ObjectStore` CRD, so a bump can change the schema that
  `k8s/infra-manifest/postgres/cluster.yaml` depends on.
- **Telemetry store** — runs **PGSTY Silo**, a community fork of MinIO, on the
  min.io `minio` chart. MinIO Inc. ended community distribution in 2025 and has
  since deleted `quay.io/minio/*`; the chart's default image stopped pulling,
  which broke the store on 2026-09-24 (see
  [Upstream withdrawal](#upstream-withdrawal)). The image is overridden in
  `k8s/infra-manifest/telemetry-store/values.yaml` and reused by the bucket Job,
  so **bumping `targetRevision` does not change the image** — bump the digest
  pin in both files. Silo keeps MinIO's data format, `MINIO_*` variables and
  metrics paths, and maps the chart's `minio` command to `silo`; before a bump,
  check its compatibility notes. Data written by MinIO `2024-12-18` was verified
  to read back byte-identical under Silo `2026-09-16`. The min.io chart itself
  is unmaintained (`5.4.0` is its last release) and could disappear the same way.

Slow/low-risk: CloudNativePG (operator; watch the PG major it manages),
Thanos, Headlamp.

## How to upgrade a common service

1. Check the new version's changelog for breaking changes / CRD updates.
2. Bump `targetRevision` in the service's `k8s/argocd/infra-apps/<svc>.yaml`.
3. If values changed, update the file under `k8s/infra-manifest/<svc>/`. Validate
   with `helm template <chart> --repo <url> --version <new> -f <values>` before
   committing (catches schema/breaking changes without touching the cluster).
4. Commit. ArgoCD syncs. Watch the app go `Synced/Healthy` and the pods roll.
5. Verify the service functionally (e.g. Grafana loads, a cert issues, Loki
   ingests) — not just that pods are Running.

## AKS upgrades

- **Patches** (`1.36.x`) and **node images**: automatic, via the `patch` and
  `NodeImage` channels in `infra/aks.bicep`. Nothing to do — deliberately, see
  below.
- **Minors** (`1.36 → 1.37`): manual. Bump `kubernetesVersion` in
  `infra/aks.bicep` + the param files, `az deployment group create` (or
  `az aks upgrade`). Do it before AKS drops support for the running minor
  (check `az aks get-versions -l <region>`). On a single-node cluster the
  upgrade is briefly disruptive — expect a short control-plane/node blip.

**Scaling down is the dangerous direction.** The pool is pinned to one
availability zone (`zones: ['1']`, [decisions.md](decisions.md) entry 15) exactly
so this is safe — Azure disks cannot cross zones, and before the pin a
replacement node could land in a zone with none of the cluster's data. If the
pool is ever spread across zones again, check where the disks are before removing
a node:

```bash
kubectl get pv -o custom-columns='CLAIM:.spec.claimRef.name,\
ZONE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values'
kubectl get nodes -L topology.kubernetes.io/zone
```

A pod whose disk is in a zone with no node stays `Pending` **permanently** with
*"node(s) didn't match PersistentVolume's node affinity"* — it does not resolve
on its own, and the fix is to add a node back in that zone.

**Why node images stay on a channel.** An automatic node-image upgrade will
replace the node, which is disruptive, and on 2026-08-24 it left the test
cluster's pool in `provisioningState: Failed` with two nodes billing instead of
one. Running upgrades by hand was considered and **rejected**: the platform is
maintained by volunteers, node images ship roughly weekly with OS CVE fixes, and
a manual step that gets forgotten is worse than an automatic one that
occasionally disrupts. The fix is to make the disruption survivable, not to move
it into a runbook nobody runs.

Four things make it survivable. The first three are in place; the fourth is a
check, not a setting:

- **One availability zone** ([decisions.md](decisions.md) entry 15) — so a
  replacement node can always reattach the cluster's disks. Without it the
  replacement landed in another zone and six workloads were stranded
  permanently.
- **`enablePDB: false` on the shared Postgres** — CNPG's PDB protects the
  primary by role, so with `instances: 1` it is *never* satisfiable and blocks
  every drain forever. AKS retries rather than forcing: the event is
  `Eviction blocked by Too Many Requests (usually a pdb): shared-1`, seen 67
  times over 7 minutes. Removing the PDB unblocked it immediately.

- **Dex keeps its signing keys across restarts** (`storage: type: kubernetes`).
  Previously an upgrade restarted Dex, rotated its key and logged **everyone**
  out; the resulting `401` looked exactly like a broken authenticator and caused
  two wrong diagnoses. Keys now persist as custom resources in etcd — no PVC.

- **Every pinned image can still be pulled.** A replacement node starts with
  an empty image cache, so each weekly upgrade re-pulls every image. An image
  deleted upstream keeps running from cache until then, and then fails with
  `ImagePullBackOff`. That is what happened on 2026-09-24: the three settings
  above all held, but the telemetry store could not pull
  `quay.io/minio/minio`, and Loki and Thanos went down with it. See
  [Upstream withdrawal](#upstream-withdrawal).

**If SSO fails, check the token's key id first.** It takes seconds and rules out
the most common cause:

```bash
curl -s https://dex.$HOST/keys | grep -o '"kid":"[^"]*"'
```

Compare with the `kid` in the token's JWT header. A mismatch means the token
predates a key rotation — log in again, nothing is wrong. Only if they **match**
and the API server still returns `401` is there a real fault to chase
([decisions.md](decisions.md) entry 16).

**Verifying after an upgrade.** Node images are checked with:

```bash
az aks nodepool get-upgrades -g $RG --cluster-name $CLUSTER -n <pool>
```

**A minor upgrade leaves Pod Security behind.** Project namespaces pin
`pod-security.kubernetes.io/enforce-version` (see
`k8s/projects/_template/infra/namespace-*.yaml`), which is deliberate — the
cluster's admission rules should not change underneath running workloads because
the control plane moved. The cost is that the pin does not follow the upgrade:
after moving to `1.37` the namespaces still enforce `1.36` semantics, silently,
and any policy tightening in the new minor is not applied.

So bump the pin as a **separate, later commit** — cluster first, verify, then the
labels. The `warn`/`audit` labels are intentionally left unpinned, so between the
two the warnings already show what the newer level would enforce. Every project
namespace carries the pin; `.github/workflows/checks.yml` fails a project
namespace committed without one, but it cannot tell a stale pin from a current
one.

## Backup strategy (Velero)

Two schedules in `k8s/infra-manifest/velero/schedules/schedules.yaml`, writing to
the `velero` container in the durable backup storage account (outside the
cluster, so it survives a teardown):

| Schedule | Scope | When | Retention |
|---|---|---|---|
| `daily-projects` | project namespaces (`"*"` minus infra), incl. PVC data | 02:00 daily | 14 days |
| `weekly-full` | every namespace, infra included | 03:00 Sundays | 90 days |

**Why the split.** Project namespaces hold state that exists nowhere else, so
they are backed up daily. Infra namespaces are reproducible from Git via ArgoCD —
a rebuild is the real recovery path, not a restore — so the weekly full backup is
a cheap safety net for API state rather than the primary mechanism.

**The maintenance obligation.** `daily-projects` is a **denylist**: it includes
`"*"` and subtracts the infra namespaces. The default for any new namespace is
therefore *to be backed up*, which is right for projects and wrong for infra.
**Adding an infra service means adding its namespace to `excludedNamespaces`** —
keep that list in step with the destination namespaces in
`k8s/argocd/infra-apps/`. Nothing enforces this and nothing alerts on it: a
missed namespace is silently swept into the daily project backup, where the only
symptom is slower backups and storage growth.

`postgres` is excluded for a different reason — the shared database has its own
CNPG `ScheduledBackup` at 02:30 (`k8s/infra-manifest/postgres/cluster.yaml`),
which is the correct way to back up a live database. Leaving it in would also
snapshot its 32Gi PVC on a second, overlapping path. It is still covered by
`weekly-full`.

### Infra volumes: what is actually protected

"Infra is reproducible from Git" is true of the **manifests**, not of the ~156Gi
of state in infra PVCs. Those are covered only by `weekly-full` (90-day
retention). Per volume:

| PVC | Size | If lost |
|---|---|---|
| `postgres/shared-<n>` | 32Gi | **Own CNPG backup at 02:30** — the real protection; Velero is secondary |
| `telemetry-store/telemetry-store` | 64Gi | Backing store for Loki + Thanos. **Weekly is the only copy** — see below |
| `monitoring/prometheus` | 32Gi | Recent metrics; long-term copies live in Thanos → telemetry store |
| `monitoring/loki` | 16Gi | Recent logs; chunks ship to the telemetry store |
| `monitoring/grafana` | 8Gi | **Gap — see below** |
| `monitoring/alertmanager` | 4Gi | Silences only; regenerate by hand |

**Two accepted decisions, recorded rather than left implicit:**

- **The telemetry store gets weekly cover only, and that is accepted.** It is
  single-node and holds observability history that Prometheus and Loki have
  already flushed to it. Losing it between weekly backups loses up to a week of
  long-term metrics and logs — annoying, not operationally critical, and the
  alternative (daily snapshots of a 64Gi volume holding derived data) is not
  worth the storage. Revisit if it ever holds something that is *not* derived.
- **Grafana is the real gap.** Dashboards are vendored in Git and provisioned,
  but **anything created through the UI lives only in this PVC**, with weekly as
  the only copy. A dashboard built on Monday and lost on Friday is gone. The
  cheap mitigation is social, not technical: build dashboards in Git
  (`k8s/infra-manifest/monitoring/dashboards/`), and treat UI-created ones as
  scratch. Moving `monitoring` into the daily schedule would fix it, but would
  also pull in the 80Gi of Prometheus/Loki/derived data alongside it.

**Verifying.** Backups fail quietly — a `Schedule` that never produces a backup
looks the same as one that does until a restore is needed:

```bash
velero schedule get                 # both schedules, and LAST BACKUP
velero backup get                   # expect a daily-projects-* from last night
velero backup describe <name>       # check Phase: Completed and the ns list
```

Watch for `PartiallyFailed` on `weekly-full` — a few un-snapshottable cluster
resources are expected there. On `daily-projects` it is not; investigate.

> **Restores are documented in [onboarding.md](onboarding.md)** ("Restore a
> namespace or PVC") and were **verified end-to-end on 2026-08-10** — real Azure
> disk snapshot, PVC deleted and restored in place with byte-identical contents,
> plus a restore into a second namespace. Two traps found in that test are
> recorded there: an empty `kubectl get volumesnapshot` is normal (Velero keeps
> only the durable Azure snapshot), and `--include-resources` silently breaks
> CSI restores unless it also names `volumesnapshots,volumesnapshotcontents`.
>
> **The scheduled backups do not yet exercise volumes.** `daily-projects`
> excludes every infra namespace and no project has a PVC, so the nightlies so
> far captured object state only. A green `Completed` on a nightly is not
> evidence that volume backup works — that only starts once a project has a PVC.

## Upstream withdrawal

Pinning protects against an upstream *change*. It does nothing about an
upstream *deletion*, and the cluster cannot tell the two apart until it next
pulls.

**What happened, 2026-09-24.** The weekly node-image upgrade replaced the node
at ~23:29 UTC. The new node could not pull
`quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z`: MinIO Inc. had deleted
its public images (`401` from quay, "object not found" on Docker Hub). The
image had run for a week only because the old node had cached it. The telemetry
store stayed in `ImagePullBackOff`; Loki and Thanos store-gateway crash-looped
on `connection refused`; ~10 warnings paged overnight. No data was lost: the
store's PVC was intact, and the Thanos sidecar keeps retrying uploads within
Prometheus's local retention. Loki ingested nothing until the store came back.
Fixed by moving to PGSTY Silo (see the telemetry store entry
[above](#upgrade-sensitive-components-read-the-changelog-first)).

**Why nothing warned.** Every signal the platform watches was green until the
pull: the pods were Running, ArgoCD Synced, and the pin had not changed.
Renovate would not have helped either — it proposes *newer* versions, and a
withdrawn project has none.

**The check.** Ask each registry whether it still serves every image the cluster
runs, the way a node would:

```bash
scripts/check-images-pullable.sh     # needs kubectl; read-only; exits 1 on any failure
```

Run it on the semi-annual cadence above, and before any planned node
replacement or rebuild. A `FAIL` means: that workload goes down at the next node
upgrade, which is at most a week away.

**Signs a project is heading this way:** no chart or image release for a year,
a licence change, "community edition" wording in release notes, or a fork
appearing with the old project's users behind it. Bitnami (2025) and MinIO
(2025–26) both showed these months before anything broke.

**What would close the gap for good:** a copy of the images we control, e.g. an
Azure Container Registry with pull-through cache. That is a design decision
(cost, and one more durable resource), not done yet.

## Automating drift detection

Consider adding **Renovate** (or Dependabot) to the repo. It watches the pinned
chart/image versions and opens PRs when new versions are available — so "what is
behind?" is answered automatically instead of by hand. Pair it with the cadence
above: merge fast-mover PRs promptly, batch the stable ones. It does **not**
detect a withdrawn image; that is
[`check-images-pullable.sh`](#upstream-withdrawal).

## Current pins (baseline)

As of the initial build:

| Component | Pin |
|---|---|
| AKS Kubernetes | 1.36 (minor alias — the patch channel owns the patch) |
| ArgoCD | v3.4.5 |
| cert-manager | v1.21.0 |
| Traefik | 41.0.2 (v3.7) |
| Gateway API CRDs | v1.5.1 |
| Telemetry store | min.io chart 5.4.0; image `pgsty/silo` RELEASE.2026-09-16 (since 2026-09-25) |
| kube-prometheus-stack | 87.19.2 |
| Loki / Alloy | 18.5.4 (grafana-community OSS fork) / 1.11.0 |
| Thanos (stevehipwell) | 1.24.0 (app 0.42.2) |
| External Secrets | 2.8.0 |
| CloudNativePG | 0.29.0 (app 1.30.0) |
| Headlamp | 0.41.0 |
| Velero | 12.1.0 (app 1.18.1) |
| CNPG Barman Cloud Plugin | v0.13.0 |

> The cluster was launched on current versions of the fast-movers (ESO, kps,
> Traefik brought to latest at build time) so the first maintenance cycle isn't a
> migration. Breaking changes handled during that bump, for reference:
> - **ESO 0.x → 2.x**: our CRs were already on the `v1` API, so no manifest change
>   — but the chart owns its CRDs, so an *in-place* upgrade from ArgoCD-installed
>   0.x CRDs needs the old CRDs removed first (helm won't adopt un-owned CRDs). A
>   fresh install is clean.
> - **Traefik v39 → v41**: the chart's top-level `logs:` key became `log:` (level
>   moved directly under it) and access logs are now a separate `accessLog:` key.

---

## Not yet implemented

Controls the design assumes but the cluster does not enforce yet. Distinct from
[Accepted risks](#accepted-risks-revisit-deliberately) below, which are decisions
to live with something, and from [decisions.md](decisions.md), which records
choices already made. These are gaps that should close.

| Gap | What it means today | What closes it |
|---|---|---|
| **No record of Key Vault secret reads** — no diagnostic setting on `infra/keyvault.bicep` | The vault is the cluster's root of trust, and `kube-audit-admin` cannot record reads either, so nothing shows which secrets were read or by whom | `Microsoft.Insights/diagnosticSettings` on the vault (`AuditEvent`) to the same workspace |
| **No image or manifest scanning in CI** — [`checks.yml`](../.github/workflows/checks.yml) validates YAML, placeholders and two security invariants only; images are pinned by tag, not digest | A compromised or vulnerable upstream tag is adopted on the next pull, silently | Trivy + kube-linter in CI; digest pinning with Renovate keeping digests current |

Two entries have left this list. API-server audit retention: `kube-audit-admin`
ships to a capped Log Analytics workspace ([decisions.md](decisions.md) entry 9) —
though it records mutations, **not reads**, which is why the Key Vault row above
stays. And Alertmanager now has a Slack receiver plus rules for the platform's own
controls failing ([decisions.md](decisions.md) entry 11), so a stalled
`ExternalSecret` or a backup that stops running is no longer silent.

Both remaining gaps are about *visibility of reads and of supply chain*, not
delivery: alerts now reach Slack, so "it would be noticed" is true of a control
that breaks. It is still not true of a secret being read — in Kubernetes or in the
vault — which is what the first row is for.

## Accepted risks (revisit deliberately)

Things we know are not ideal, why they are that way, and what would close them.
Listed so a later reader finds a decision rather than an oversight.

Both network entries below share one root cause: **AKS egresses through a
managed outbound IP that Azure reassigns on every cluster rebuild**
(`outboundType: 'loadBalancer'` in `infra/aks.bicep`). Pinning that to a static
Public IP is the single change that makes firewalling either resource
practical — worth doing first if this is revisited.

### Key Vault is reachable from any network

`infra/keyvault.bicep` sets `networkAcls.defaultAction: Allow`, so the vault
endpoint answers on the public internet.

**This is the higher-value target of the two.** The vault is the cluster's root
of trust — it holds the **Sealed Secrets private key** (which decrypts every
`SealedSecret` committed to the public repo), the backup storage-account key,
the Dex and Grafana GitHub client secrets, and the telemetry store's root
credentials.
Compromise here is worse than compromise of the backup account.

**What protects it.** Authorization is Azure **RBAC**, not legacy access
policies (`enableRbacAuthorization: true`), so reaching the endpoint grants
nothing without a role assignment. Soft-delete is on with 90-day retention and
purge protection is enabled, so secrets cannot be permanently destroyed by an
attacker or a mistake. A **`CanNotDelete` resource lock** covers the vault
itself, which soft-delete does not: it makes deletion a deliberate two-step act
rather than one command. What the open endpoint exposes is the **authentication
surface** — credential probing and any future Azure-side auth flaw.

**Why it is open.** The same constraint as the backup account: ESO reads the
vault from inside the cluster over the AKS **managed outbound IP**, which Azure
reassigns on every rebuild, and admins run `az keyvault` from arbitrary
networks. An IP allow-list would break secret sync after each teardown — and
because ESO failures surface as an `ExternalSecret` that simply stops
refreshing, that breakage is quiet.

**What would close it,** once the cluster stops churning: a **Private Endpoint**
plus Private DNS, or `defaultAction: 'Deny'` with the AKS outbound IP pinned to a
**static Public IP** and the admin IPs listed. Both are more attractive here than
for the backup account, given what is stored.

**Interim mitigation that costs nothing:** keep the RBAC assignments minimal
(ESO holds only `Key Vault Secrets User`, i.e. read) and prefer per-secret scopes
over vault-wide roles for any future consumer. An open endpoint plus a
least-privilege role is a much smaller problem than an open endpoint plus a
broad one.

### Backup storage is reachable from any network

`infra/backup-storage.bicep` sets `networkAcls.defaultAction: Allow`, so the
storage account holding **all cluster backups** answers on the public internet.

**What that does and does not mean.** The data is not public:
`allowBlobPublicAccess` is false, every container is `publicAccess: None`,
HTTPS-only, TLS 1.2 minimum, and reading a backup needs a valid credential
(Velero's Workload Identity, or CloudNativePG's account key). What is exposed is
the **authentication endpoint** — surface for credential probing, and a larger
blast radius if the CNPG account key ever leaks.

**Why it is open.** The shared root cause above: the outbound IP changes on
every rebuild, so an IP allow-list would break Velero and CNPG backups after each
teardown — and a stalled backup is the failure nobody notices until a restore is
needed. Admins also run `az storage` against it from arbitrary networks.

**What would close it,** once the cluster stops churning:

- a **Private Endpoint** + Private DNS (~€7/month; admin access then needs a jump
  host or VPN), or
- `defaultAction: 'Deny'` with the AKS outbound IP pinned to a **static Public
  IP** so it survives rebuilds, plus the admin IPs.

**What protects the account itself.** Two things, both declared in
`infra/backup-storage.bicep` so a rebuild cannot skip them:

- **A `CanNotDelete` resource lock.** Blob soft-delete (30 days) recovers a
  deleted *backup*; it does nothing about a deleted *account*. The lock is
  deliberately `CanNotDelete` and not `ReadOnly` — `ReadOnly` would block
  `az storage account keys list`, which install.md needs for the CNPG Barman
  key. Because a lock on any resource also blocks deleting its resource group,
  this protects `$INFRA_RG` as a whole; the same lock is on the Key Vault and
  the audit workspace. A resource lock was chosen over a resource-group lock so
  that DNS record sets in the same group stay deletable.

  A deliberate deletion means removing the lock first — the point is that it
  cannot happen by accident or in a single command:

  ```bash
  az lock delete -n no-delete -g $INFRA_RG \
    --resource $BACKUP_STORAGE_ACCOUNT --resource-type Microsoft.Storage/storageAccounts
  ```

- **`Standard_RAGZRS` redundancy.** Zone-redundant in the primary region *and*
  geo-replicated, with read access to the secondary — so a regional Azure
  failure does not take the backups with it, and they can be read during one
  without waiting for a failover. **Not `Standard_GRS`:** its primary replica is
  LRS, so moving `ZRS → GRS` would have *traded away* zone redundancy rather
  than adding geo. Measured cost (Cool tier, Sweden Central): 0.01250 → 0.02250
  USD/GB/month, about 1.8×, on an account holding backup metadata and Postgres
  base backups rather than PVC contents.

**The bigger lever is the key, not the firewall.** `allowSharedKeyAccess: true`
exists only because the CNPG Barman plugin's Managed-Identity path is finicky
with multiple node identities; Velero already needs no key. When that path is
reliable, dropping shared-key access removes the credential this exposure would
amplify — worth more than the network restriction on its own.
