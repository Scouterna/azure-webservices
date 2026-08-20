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
  upgrade is recoverable.

## Cadence by component

Based on each project's real release velocity and blast radius:

| Cadence | Components | Notes |
|---|---|---|
| **Quarterly** (fast-movers) | kube-prometheus-stack, Traefik, ArgoCD, Grafana/Loki/Alloy | Release often; chart-major bumps can change values. Review changelogs. |
| **Semi-annual** (stable) | cert-manager, MinIO, CloudNativePG, Thanos, Headlamp, External Secrets, Gateway API CRDs | Slower cadence, fewer breaking changes. Bump the Gateway API CRDs in step with Traefik (see below). |
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

Slow/low-risk: MinIO, CloudNativePG (operator; watch the PG major it manages),
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

- **Patches** (`1.36.x`): automatic via the `patch` upgrade channel + NodeImage
  channel in `infra/aks.bicep`. Nothing to do.
- **Minors** (`1.36 → 1.37`): manual. Bump `kubernetesVersion` in
  `infra/aks.bicep` + the param files, `az deployment group create` (or
  `az aks upgrade`). Do it before AKS drops support for the running minor
  (check `az aks get-versions -l <region>`). On a single-node cluster the
  upgrade is briefly disruptive — expect a short control-plane/node blip.

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
| `weekly-full` | every namespace, infra included | 03:00 Sundays | 35 days |

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

"Infra is reproducible from Git" is true of the **manifests**, not of the ~124Gi
of state in infra PVCs. Those are covered only by `weekly-full` (35-day
retention). Per volume:

| PVC | Size | If lost |
|---|---|---|
| `postgres/shared-1` | 32Gi | **Own CNPG backup at 02:30** — the real protection; Velero is secondary |
| `minio/minio` | 32Gi | Backing store for Loki + Thanos. **Weekly is the only copy** — see below |
| `monitoring/prometheus` | 32Gi | Recent metrics; long-term copies live in Thanos → MinIO |
| `monitoring/loki` | 16Gi | Recent logs; chunks ship to MinIO |
| `monitoring/grafana` | 8Gi | **Gap — see below** |
| `monitoring/alertmanager` | 4Gi | Silences only; regenerate by hand |

**Two accepted decisions, recorded rather than left implicit:**

- **MinIO gets weekly cover only, and that is accepted.** It is single-node and
  holds observability history that Prometheus and Loki have already flushed to
  it. Losing it between weekly backups loses up to a week of long-term metrics
  and logs — annoying, not operationally critical, and the alternative (daily
  snapshots of a 32Gi volume holding derived data) is not worth the storage.
  Revisit if MinIO ever holds something that is *not* derived.
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

## Automating drift detection

Consider adding **Renovate** (or Dependabot) to the repo. It watches the pinned
chart/image versions and opens PRs when new versions are available — so "what is
behind?" is answered automatically instead of by hand. Pair it with the cadence
above: merge fast-mover PRs promptly, batch the stable ones.

## Current pins (baseline)

As of the initial build:

| Component | Pin |
|---|---|
| AKS Kubernetes | 1.36 (minor alias — the patch channel owns the patch) |
| ArgoCD | v3.4.5 |
| cert-manager | v1.21.0 |
| Traefik | 41.0.2 (v3.7) |
| Gateway API CRDs | v1.5.1 |
| MinIO | 5.4.0 |
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
| **Alertmanager has no receiver** | Alert rules exist and fire, but nothing leaves the cluster — including the governance alerts above and any future signal that a control has stopped working | A receiver (email/Slack/webhook) and a deliberate route |
| **No image or manifest scanning in CI** — [`checks.yml`](../.github/workflows/checks.yml) validates YAML, placeholders and two security invariants only; images are pinned by tag, not digest | A compromised or vulnerable upstream tag is adopted on the next pull, silently | Trivy + kube-linter in CI; digest pinning with Renovate keeping digests current |

API-server audit retention is no longer here: `kube-audit-admin` ships to a capped
Log Analytics workspace ([decisions.md](decisions.md) entry 9). Two caveats keep the
rows above: it records mutations, **not reads**, and nothing alerts on it — though
for this workspace the useful alerts are Azure-side and do not wait on Alertmanager.

The Alertmanager gap compounds the other two: several controls fail quietly
(a stalled `ExternalSecret`, a backup that archives nothing), and until something
delivers alerts, "it would be noticed" is not true of any of them.

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
the Dex and Grafana GitHub client secrets, and the MinIO root credentials.
Compromise here is worse than compromise of the backup account.

**What protects it.** Authorization is Azure **RBAC**, not legacy access
policies (`enableRbacAuthorization: true`), so reaching the endpoint grants
nothing without a role assignment. Soft-delete is on with 90-day retention and
purge protection is enabled, so secrets cannot be permanently destroyed by an
attacker or a mistake. What the open endpoint exposes is the **authentication
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

**The bigger lever is the key, not the firewall.** `allowSharedKeyAccess: true`
exists only because the CNPG Barman plugin's Managed-Identity path is finicky
with multiple node identities; Velero already needs no key. When that path is
reliable, dropping shared-key access removes the credential this exposure would
amplify — worth more than the network restriction on its own.
