# Decisions

Choices that shape this cluster, why they were made, and what was rejected. The
point of the "rejected" column is to stop settled questions being reopened every
few months — if an entry says **settled**, it is not a to-do.

Add an entry when a choice is made that a later reader would otherwise mistake for
an oversight. Amend an entry when the reasoning changes; mark it **superseded** and
say why rather than deleting it.

| # | Decision | Status |
|---|---|---|
| [1](#1-developers-authenticate-as-their-github-identity) | Developers authenticate as their GitHub identity, not Entra | settled |
| [2](#2-the-static-cluster-admin-certificate-stays) | The static cluster-admin certificate stays | settled, follows from 1 |
| [3](#3-project-namespaces-enforce-baseline-not-restricted) | Project namespaces enforce `baseline`, not `restricted` | current, revisitable |
| [4](#4-pod-security-enforce-version-is-pinned) | Pod Security `enforce-version` is pinned | current |
| [5](#5-imds-egress-is-denied-with-a-deny-rule-not-an-allow-list) | IMDS egress denied with a deny rule, not an allow-list | current |
| [6](#6-external-secrets-write-access-is-not-in-admin-and-the-store-is-scoped) | ESO write access is not in `admin`; the store is scoped | current |
| [7](#7-the-vault-has-no-per-key-scoping) | The vault has no per-key scoping | accepted limit |
| [8](#8-a-namespace-is-a-security-boundary-the-appproject-is-not-the-only-one) | A namespace is a security boundary; the AppProject bounds only GitOps | current |
| [9](#9-audit-logging-is-kube-audit-admin-only-capped-and-off-cluster) | Audit logging is `kube-audit-admin` only, capped, and off-cluster | current |
| [10](#10-the-template-declares-the-outbound-ip-counts) | The template declares the outbound IP counts | current |
| [11](#11-alerts-go-to-slack-and-info-level-is-dropped) | Alerts go to Slack, and info-level is dropped | current |
| [12](#12-gitops-is-argocd-not-flux) | GitOps is ArgoCD, not Flux | settled |
| [13](#13-the-default-appproject-is-emptied) | The `default` AppProject is emptied | current |
| [14](#14-projects-read-their-own-argocd-status-via-kubernetes-rbac-not-an-argocd-ui) | Projects read their own ArgoCD status via RBAC, not an ArgoCD UI | current |
| [15](#15-the-node-pool-is-pinned-to-one-availability-zone) | The node pool is pinned to one availability zone | current |
| [16](#16-node-image-upgrades-stay-automatic-and-the-shared-postgres-has-no-pdb) | Node-image upgrades stay automatic; the shared Postgres has no PDB | current |

---

## 1. Developers authenticate as their GitHub identity

**Settled.** Dex federates to GitHub, and the API server trusts Dex through a
JWTAuthenticator. A developer *is* their GitHub login; a team is a GitHub team.
There are no ServiceAccount tokens to distribute.

**Why.** Project developers are volunteers. Most are not in Scouterna's Entra
tenant and should not have to be, and GitHub is where they already are. It also
keeps RBAC portable: bindings name GitHub teams rather than tenant-specific object
IDs.

**Rejected: managed Entra integration (`aadProfile`) with Azure RBAC.** It would
require every developer to exist as a user or guest in the tenant, and would tie
RBAC to Entra object IDs against the portability goal. Secondary objections:
enabling it cannot be undone on an existing cluster, and its interaction with the
JWTAuthenticator is untested. **This is not pending a test** — the identity model
is the reason, and a test cannot change it.

**Cost, accepted.** The JWTAuthenticator is an AKS preview feature applied
out-of-band with `az` ([install.md](install.md) §8b), so the developer path depends
on a preview capability. Revocation is removing someone from the GitHub team, which
takes effect on their next login; an already-issued token stays valid until it
expires (`idTokens: 24h`).

See [cluster-access.md](cluster-access.md).

## 2. The static cluster-admin certificate stays

**Settled, as a consequence of 1.** `az aks get-credentials --admin` remains
available. [install.md](install.md) §12 deletes the file after bootstrap, but the
capability cannot be removed.

**Why.** `disableLocalAccounts` is the property that would remove it, and AKS
rejects it on a cluster without Entra integration — in ARM preflight, not at the
Bicep type level: *"Since kubernetes version 1.25, disableLocalAccounts can only be
set on Azure AD integration enabled cluster."* Confirmed 2026-07-21 and again
2026-08-18 against API `2026-03-01` on Kubernetes 1.36. Entra is ruled out by 1, so
the precondition is permanently unavailable.

**Superseded: setting `disableLocalAccounts: true` in Bicep.** Attempted, and
reverted — it fails preflight, which would have broken the `nodeCount`
bump-and-redeploy workflow on first use. Worth recording *why* it looked fine: the
property is valid, so `bicep build` accepted it and a CI check confirmed it reached
the resource. Both verify the type system; the constraint lives in AKS preflight.
`az deployment group validate` is the check that catches this class.

**The control instead.** The Azure rights permitting `az aks get-credentials
--admin` are the only route to cluster-admin outside SSO, so they are the real
mitigation: `Azure Kubernetes Service Cluster Admin Role` and RG `Contributor` to
as few people as possible, PIM-eligible rather than standing.

## 3. Project namespaces enforce `baseline`, not `restricted`

**Current, deliberately revisitable.** Both namespace templates set
`pod-security.kubernetes.io/enforce: baseline`, with `restricted` as `warn` and
`audit`.

**Why.** `baseline` rejects the class of pod that reaches the node — privileged,
host namespaces, `hostPath`, `hostPort`, added capabilities — which is what makes
namespace `admin` safe on a single-node cluster. `restricted` additionally forbids
running as root in the container, which breaks a large share of upstream images
without closing anything `baseline` leaves open.

**Rejected for now: `enforce: restricted`.** Setting it as `warn`/`audit` shows
projects what a tightening would require while nothing breaks, which is the path to
adopting it later. Tightening is a real option, not a formality — it just needs the
warnings to be clean first.

**Not available: a cluster-wide default.** A managed AKS cluster does not accept an
`--admission-control-config-file`, so an unlabelled namespace cannot be made to
default to `restricted`. The labels are the whole mechanism, which is why CI asserts
they are present.

See [security.md](security.md) §2.

## 4. Pod Security `enforce-version` is pinned

**Current.** Project namespaces pin `enforce-version` to the cluster's minor
(`v1.36`); `warn` and `audit` are deliberately left unpinned.

**Why.** Admission behaviour should not change under running workloads because the
control plane moved — the same "pin everything, upgrade deliberately" rule the rest
of the platform follows. Leaving `warn`/`audit` unpinned means the newer level's
findings are visible before it is enforced.

**Cost, accepted.** The pin does not follow an AKS upgrade: after moving to 1.37 the
namespaces still enforce 1.36 semantics, silently. Bumping it is a separate commit
after the cluster upgrade — recorded under AKS upgrades in
[maintenance.md](maintenance.md).

**Rejected: `enforce-version: latest`.** It tracks the control plane, which is the
thing the pin exists to prevent. CI rejects it, because it is a valid PSA value and
would otherwise pass unnoticed.

## 5. IMDS egress is denied with a deny rule, not an allow-list

**Current.** A `CiliumClusterwideNetworkPolicy` denies egress to
`169.254.169.254/32` from every namespace except `kube-system`, with
`enableDefaultDeny: {egress: false, ingress: false}`.

**Why a deny rule.** In Cilium, an endpoint selected by any *allow* egress rule
flips to default-deny egress. A cluster-wide allow-list would have to enumerate
every legitimate destination of every pod, and one omission is an outage. A deny
rule cannot break traffic it does not mention.

**Why `NotIn [kube-system]`** rather than naming project namespaces: a namespace
created later is denied by default, so a new infra component that needs the node
identity fails visibly at deploy time instead of a new project quietly inheriting
the escalation path.

**Not done: a default-deny NetworkPolicy baseline.** Pod-to-pod traffic is still
unrestricted. Projects *may* ship their own `NetworkPolicy` (their AppProject
whitelists the kind); a platform-wide baseline needs a real project to test
against. Also not covered: the WireServer at `168.63.129.16`, which serves platform
DNS and health probes and so needs its own analysis.

See [security.md](security.md) §1.

## 6. External Secrets write access is not in `admin`, and the store is scoped

**Current.** `rbac.aggregateToAdmin` and `rbac.aggregateToEdit` are false, so the
operator's write permissions are not folded into the built-in roles. The
`ClusterSecretStore` carries `spec.conditions` naming the six infra namespaces that
use it, plus a `scouterna.se/keyvault-access: "true"` selector for project
namespaces.

**Why both.** The RBAC half is load-bearing: project namespaces must remain
eligible for the store, because a project with a database reads its password from
the vault, so scoping alone would not have closed the path. Turning off the
aggregation removes the capability instead of narrowing where it applies.

`rbac.aggregateToView` stays **on**: read-only access lets a developer see whether
their own secret synced, exposing the key name but never the value.

**Worth knowing before re-enabling either flag.** The aggregated role covered 23
resources, not just `externalsecrets` — including `PushSecret`/`ClusterPushSecret`,
which write *into* the vault, and the generator kinds, one of which (`Webhook`)
makes the controller issue an arbitrary HTTP request and capture the response into
a Secret. `aggregateToView` is the flag for granting read.

See [security.md](security.md) §3.

## 7. The vault has no per-key scoping

**Accepted limit.** Membership of the store's `conditions` grants read access to
the *whole* vault. The limit is which namespaces may use the store, not which keys
they may read.

**Why accepted.** Real per-project scoping needs a separate managed identity per
project, Azure RBAC assigned at **secret** scope, and a `SecretStore` per project to
use it — per-project Azure work on every onboarding. Not justified while the
projects are few and infra-run.

**What follows.** Treat presence in `conditions` as "trusted with every secret in
the vault", keep the vault's own role assignments minimal, and put only what a
namespace needs into it. Revisit when the first project the infra group does not run
needs vault access.

## 8. A namespace is a security boundary; the AppProject is not the only one

**Current.** With `baseline` Pod Security and the IMDS deny in place, a project
namespace is a boundary rather than a convenience.

**Why this needs stating.** The AppProject whitelist is labelled the security
boundary, and for the GitOps path it is one. But the platform deliberately allows
projects to deploy **by hand** with `kubectl`, which never passes through ArgoCD —
so for that route the boundary is Kubernetes RBAC plus Pod Security, and the two do
not match exactly. `admin` permits `RoleBinding`, `Role`, `ServiceAccount` and
`Secret` in its own namespaces even though the AppProject excludes them.

**What follows.** The excluded-kinds table in [onboarding.md](onboarding.md) is a
statement of ownership, not purely a technical fence: creating those by hand is out
of bounds and gets reverted. Closing the gap technically would need a
`ValidatingAdmissionPolicy`, which is not deployed.

## 9. Audit logging is `kube-audit-admin` only, capped, and off-cluster

**Current.** A diagnostic setting on the cluster ships the `kube-audit-admin`
category to a Log Analytics workspace in the durable infra RG, capped at 1 GB/day
with 30-day retention.

**Why off-cluster, in the durable RG.** An audit log exists to answer "what
happened", including when what happened is the cluster being destroyed. Storing it
inside the cluster, or in the cluster's own resource group, means the one event
you most need it for takes it with it.

**Why `kube-audit-admin` and not `kube-audit`.** `kube-audit-admin` drops
non-mutating reads. `kube-audit` is the full firehose — several GB/day on an idle
cluster — which on a metered workspace is the entire budget.

Be clear about what that costs, because it is not merely noise: **reads are not
recorded.** `kubectl get secrets -A -o yaml` — which retrieves the Sealed Secrets
sealing key and every project credential — is a `get`/`list`, so it leaves no
trace. Nor does a developer probing across a namespace boundary, whose 403s are
also reads. So this records **who changed what, and who shelled into a pod**
(`exec`, `attach`, `portforward` and `TokenRequest` are all `create`), and not who
read what. Recovering the read side means auditing Key Vault, not raising this
category — see "What this does not give".

**Why not `guard`.** That category audits managed **Entra ID** authentication and
Azure RBAC decisions. This cluster deliberately uses neither (decision 1), so it
would emit nothing. Worth stating because `guard` is the standard recommendation
and appears in most AKS hardening guides — it is simply not applicable here.

**The cap loses data, deliberately.** At 1 GB/day, ingestion **stops** for the rest
of the UTC day once the cap is hit, and the workspace keeps reporting healthy. That
is an audit gap precisely when something is generating unusual API traffic — the
moment you would most want the log. The alternative is an uncapped metered resource
on a cluster with no spend alerting, which for a volunteer-run NGO is the worse
failure. Raise `dailyQuotaGb` if that judgement is wrong; the trade is explicit
rather than hidden.

**It is also cheap to abuse, and that needs no Azure rights.** A developer with
`admin` in one namespace can loop a mutating call — every request is logged — and
fill 1 GB in minutes, after which everything they do is unrecorded until the UTC
day rolls over. The flood itself is visible in the rows ingested before the cap,
but only to someone looking. The Azure-side cap alert below is what makes it
noticed rather than merely recorded.

**30 days interactive, one year archived.** Log Analytics includes 31 days of
interactive retention at no extra cost, so 30 is the longest queryable window with
no per-GB-month charge. Beyond that the rows move to **archive** for a total of 365
days: an incident here will surface incidentally and late (see below), and archive
storage is a fraction of ingestion cost, so a year of recoverable history is cheap
insurance. Searching the archive needs a search job or restore rather than a plain
query — slower, but it exists.

This is applied as a step in [install.md](install.md) §11 rather than in
`loganalytics.bicep`, because the resource-specific `AKSAuditAdmin` table does not
exist until the cluster's diagnostic setting has created it — and §5b runs before
the cluster does. It could move into Bicep if the table turns out to be
pre-configurable; nobody has established that.

**Retention is not retroactive, which makes that step matter more than it looks.**
Raising retention later does not recover rows that have already aged out — they are
gone. So the §11 step is not tidying-up to be done eventually: every day it is
deferred on a running cluster silently spends a day of history the archive was
supposed to keep. On a rebuild it is durable, since the workspace outlives the
cluster and the table setting persists with it.

**What this does not give.** Attribution for the local admin certificate is still
Azure-side only — requests arrive as `masterclient` whatever the audit log records
(see [cluster-access.md](cluster-access.md)). And **Key Vault reads are not
audited**: no diagnostic setting exists on the vault, so there is no record of which
secrets were read from the cluster's root of trust. Given that this category cannot
record Kubernetes reads either, that is the notable remaining gap — it is the half
of the original finding this change does not close, and it stays listed in
[maintenance.md](maintenance.md). **Alerting for this workspace is Azure-side.**
In-cluster alerting now exists (entry 11), but this workspace never depended on it
and still should not — these rules must fire when the cluster is the problem:
`infra/alerts.bicep` carries an action group with an email receiver and two rules,
deployed outside the cluster so they still fire when the cluster is the problem.

- **`audit-pipeline-deleted`** — an Activity Log alert on
  `Microsoft.Insights/diagnosticSettings/delete` and
  `Microsoft.OperationalInsights/workspaces/delete`. This is the tamper case:
  deleting either stops collection silently, and the Activity Log is the only place
  it is recorded. Scoped to the subscription, because the point is to catch a delete
  wherever it happens.
- **`audit-ingestion-capped`** — a log query rule on `_LogOperation`, firing when the
  daily cap stops ingestion. Without it the cap is invisible: the workspace keeps
  reporting healthy while dropping everything, which is what makes the cap abusable
  rather than merely inconvenient.

**Cost, stated precisely rather than as "free".** The action group and the Activity
Log alert cost nothing. The cap rule is an Azure Monitor **log** alert and is billed
per rule per month — small, but not zero. If that is unwanted, delete the rule and
rely on the quarterly `dataIngestionStatus` check in
[maintenance.md](maintenance.md) instead; the trade is detection latency measured in
months rather than minutes.

**The workspace may contain secret material, and is treated as though it does.**
`AKSAuditAdmin` has `RequestObject` and `ResponseObject` columns — "Kubernetes API
object from the request in object format" — and a `Level` column whose values
include `RequestResponse`. This category records `create`, `update` and `patch`,
which are exactly the verbs External Secrets uses to materialise a Secret. If AKS
populates those columns for `secrets`, then the Sealed Secrets private key, MinIO's
root credentials and every project's PostgreSQL password are in this workspace in
plaintext — base64 is an encoding, not encryption — and read access to it is
equivalent to read access to every secret in the cluster.

**Whether it actually does is unverified**, and deliberately recorded as open
rather than assumed either way. The columns and the audit level are documented;
what AKS's managed audit policy emits for `secrets` on this cluster is not, and
there is no workspace yet to query. Settle it once §5b has run:

```kusto
AKSAuditAdmin
| where ObjectRef.resource == "secrets" and Verb in ("create","update","patch")
| project TimeGenerated, Verb, ObjectRef, Level, RequestObject
| take 5
```

If `RequestObject` carries the Secret's `data`, either drop it at ingestion with a
workspace transformation — `AKSAuditAdmin` supports DCR transformations, so the
column can be redacted for `ObjectRef.resource == "secrets"` before it is
stored — or accept it and say so here, in which case the workspace is a
secret-tier resource and its RBAC has to match the vault's. Amend this entry with
the answer rather than leaving the question implicit.

**Reading the audit log is a separate grant.** `enableLogAccessUsingOnlyResourcePermissions`
is `false`, so querying requires a role on the workspace itself — not merely `Reader`
on the cluster. That matters because the same Azure rights that mint the admin
certificate would otherwise also read the record of what it did — and, given the
paragraph above, possibly the secrets themselves. Until the query settles that,
this setting is load-bearing rather than merely conservative, and should not be
relaxed to `true` for query convenience.

Follow that through when granting access: **treat read on this workspace as read on
every secret in the cluster**, and hand it out on that basis — the same bar as a
role on the Key Vault, not the bar for a monitoring dashboard. A year of archived
rows widens that, not narrows it.

**Why a year and not 30 days.** With no detection in place, an incident will
surface incidentally — a project reports something odd, a bill looks wrong, a
credential turns up somewhere — which is routinely months, not weeks. A 30-day
window would mean that in the most likely timeline the answer to "who did this" had
already been deleted, while the control still read as present. It would also be
shorter than the 90-day Azure Activity Log it exists to be correlated with. The
archive closes both gaps for a small fraction of the ingestion cost.

**This workspace is audit-dedicated.** Anything else pointed at it — Defender for
Containers especially — would compete for the same 1 GB and could blind the audit
log as a side effect of adding a security control. Give it its own workspace or
recalculate the cap first.

## 10. The template declares the outbound IP counts

**Current.** `aks.bicep` sets `networkProfile.loadBalancerProfile.managedOutboundIPs`
to `count: 1` and `countIPv6: 1`, matching what the cluster is actually running.

**Why it has to be declared.** The cluster is dual-stack, and ARM's default for
`countIPv6` is **0** — outbound IPv6 is opt-in, unlike `count`, which defaults to
1. Azure allocated the v6 outbound IP when the cluster was created, but the
template never mentioned it. An incremental redeploy therefore reset it to the
default: `what-if` against the live test cluster showed
`managedOutboundIPs.countIPv6: 1 → 0`, which drops the cluster's IPv6 outbound
address and IPv6 egress with it, while AAAA records still resolve to the cluster.

**Why that mattered more than it looks.** The redeploy path is routine, not
exceptional — `aks.bicep`'s own `nodeCount` description calls bumping it and
redeploying *the* way to add a node (autoscaling is deliberately off), and
enabling the audit diagnostic setting on an existing cluster needs the same
redeploy. So the trap sat on the ordinary
scaling path, and would have been discovered as broken IPv6 egress some time after
an unrelated change.

**The general rule this is an instance of.** *A property Azure defaults and the
template does not declare is not stable — it is whatever the last write said.*
`what-if` is what surfaces it, and only against a **live** cluster; `bicep build`
cannot, since nothing is syntactically wrong. Worth running before any redeploy of
an existing cluster, and worth reading past the noise: read-only computed fields
like `effectiveOutboundIPs` always show as `Delete` and mean nothing, while a
`Modify` with a concrete before/after is real.

**Not addressed here:** the other properties in the same `what-if` output
(`nodeResourceGroup`, `storageProfile`, `windowsProfile`, `identityProfile` and
similar) also appear as `Delete`. Those are Azure-defaulted and left alone by an
incremental deploy — verified by the same what-if run, which reported no change to
them once `countIPv6` was declared. If a future what-if shows one of them as a
`Modify`, treat it the way this one was treated.

## 11. Alerts go to Slack, and info-level is dropped

**Current.** Alertmanager posts to `#webservices-alerts` via a Slack webhook. The
webhook URL comes from Key Vault through an `ExternalSecret` and is read with
`slack_api_url_file`, so it never appears in the values file or in the rendered
config Secret.

**Why there was nothing before.** The chart's default config routes every alert to
a receiver named `"null"`. With 155 chart-shipped rules plus the governance ones,
roughly 158 alert rules were firing into it — the platform looked instrumented and
delivered nothing.

**`info` is dropped, deliberately.** On a single-node cluster the info-level rules
are mostly steady-state noise, and the fastest way to make a new alerting channel
useless is to fill it on day one. `critical` gets its own route with a 1h repeat;
`warning` groups on the 12h default. `Watchdog` goes to `"null"` — it fires
constantly by design and only matters if you are checking that the pipeline itself
works. Raising `info` back up is a one-line change once the channel is quiet.

**Setting `config` replaces the chart default wholesale**, so the four inhibit
rules are carried over by hand rather than inherited. They are what stops one
critical alert dragging its warning and info siblings along. Dropping them would
not error — it would just get noisy.

## What the rules actually watch

A receiver alone would have delivered 155 generic Kubernetes alerts and still
nothing about this platform's own controls, all of which fail quietly:
`governance/platform-health.yaml` adds five rules for exactly those.

| Alert | The quiet failure it catches |
|---|---|
| `ExternalSecretNotReady` | The Secret keeps serving its last synced value, so the workload runs fine until a rotation or rebuild |
| `VeleroBackupFailing` | Backups erroring; only matters when a restore is needed |
| `VeleroNoRecentBackup` | Worse — not failing, just not running |
| `PostgresWALArchivingFailing` | The database serves queries perfectly while archiving nothing |
| `ArgoCDAppNotSynced` | GitOps stopped converging, so every control in this repo quietly stops being enforced |

**Metric names were cross-checked against the committed dashboards**, not written
from memory. That caught one: the archiver metric is `cnpg_pg_stat_archiver_*`, not
`cnpg_collector_pg_stat_archiver_*` — a plausible-looking name that would never
match, giving a rule that looks healthy and never fires.

`argocd_app_info` is the exception with no corroboration in the repo, because
**ArgoCD was not being scraped at all** — it ships metrics Services and no
ServiceMonitor, so `governance/servicemonitor-argocd.yaml` adds one. Confirm that
rule has a target before trusting it (install.md §11).
## 12. GitOps is ArgoCD, not Flux

**Settled.** Evaluated on 2026-08-12 and re-checked on 2026-08-22 against the
running cluster. Flux is a good tool; it is not the right one for *this* design.
**Why.** The multi-tenancy model is the whole argument. An `AppProject` expresses,
in one file a reviewer reads top to bottom, that a project may deploy **only these
kinds**, **only into its own namespaces**, **only from its own repo** — and names
the escalation paths it excludes. That file is labelled the security boundary
because it is: projects run their own GitOps repos that nobody on the infra side
reviews, so the whitelist is the only thing between a commit in their repo and the
cluster.

Flux isolates differently: a `Kustomization` impersonates a ServiceAccount and
RBAC does the rest. Reaching the same result means per-project ServiceAccounts and
Roles enumerating allowed verbs and kinds, and depending on
`spec.serviceAccountName` being set correctly on every `Kustomization`. Two
consequences:

- **Kind allowlisting through RBAC is scattered and easier to get subtly wrong.**
  "No `ExternalSecret`, no `SealedSecret`, no `RoleBinding`" stops being one
  reviewable list.
- **The source-repo restriction largely disappears.** RBAC constrains *what* is
  applied, not *where it came from*. The `sourceRepos` pin has no Flux
  counterpart; you would rely on only infra committing the `GitRepository`.

That second point is the sharper one, and worth conceding openly if challenged:
this design deliberately keeps repo-origin and applied-kinds as two independent
controls, and Flux collapses them into one.

The same reasoning covers `project-infra`, the privileged lane, whose own comment
warns that its RoleBinding + `namespace: '*'` combination is the escalation path
in this cluster. Under Flux both lanes are `Kustomization` objects separated only
by which ServiceAccount they impersonate — a less legible separation for exactly
the object that can mint RoleBindings anywhere.

**Where Flux would have been fine or better**, stated because conceding it
strengthens the rest:

- **ApplicationSet is genuinely awkward.** `gitops-appset.yaml` needs a matrix
  generator, `elementsYaml` and a `templatePatch` purely because
  `syncPolicy.automated` is presence-based and cannot be conditionally templated.
  Flux's per-project `Kustomization` files would be plainer, at the cost of one
  file per project-environment instead of one generator.
- **Helm handling.** Flux's `HelmRelease` performs a real `helm install/upgrade`;
  ArgoCD renders and applies. The handover story in
  [argocd.md](argocd.md) — capture hand edits with `helm get values` — would be
  slightly more natural under Flux.

**One argument that has since reversed.** The 2026-08-12 assessment noted that
running ArgoCD with no GUI forfeits its main advantage. That changed when project
teams asked to see their own sync status: ArgoCD has a first-party UI that
integrates with the existing Dex, and Flux has none (Weave GitOps is third-party
and lost its corporate backing). What was a point against ArgoCD is now a point
for it.

**Migration cost, if it is ever asked.** `Application` and `ApplicationSet`
objects would be mechanical to convert. The `AppProject`s would need a from-scratch
RBAC redesign. Stating that plainly is better than claiming there is no lock-in.

## 13. The `default` AppProject is emptied

**Current.** `k8s/argocd/projects/default.yaml` overrides ArgoCD's built-in
`default` project with empty `sourceRepos`, `destinations`,
`clusterResourceWhitelist` and `namespaceResourceWhitelist`.

**Why.** ArgoCD creates `default` at startup permitting **any repo, any
namespace, and every cluster-scoped kind**, and it *cannot be deleted* — upstream
documents that it may be modified but not removed, and recommends emptying it in
multi-tenant setups. Left alone it is a fully permissive project sitting beside
the AppProject whitelist that entry 12 identifies as the entire security boundary.

**It was not a live escalation when this was written**, and the entry records that
so a future reader does not over-read it: no Application referenced `default` (23
on `infra`, 2 on `project-infra`), and project developers cannot create
Applications at all — verified by impersonation. The point is that "nobody uses
it" is a weaker guarantee than "it cannot be used", and the cost of the stronger
one is a nine-line file.

**Consequence, by design.** Any Application that omits `spec.project`, or names
`default` explicitly, now fails to sync instead of deploying with unrestricted
permissions. That is the intended behaviour: project assignment becomes
deliberate. An Application that suddenly cannot sync after this lands is telling
you it never named a project.


## 14. Projects read their own ArgoCD status via Kubernetes RBAC, not an ArgoCD UI

**Current.** A project that wants to see whether ArgoCD is syncing its manifests
gets a `Role` in the `argocd` namespace scoped with `resourceNames` to its own
`Application` objects, bound to its GitHub team. There is no ArgoCD web UI, and
`argocd-server` is not exposed. The template is
`k8s/projects/_template/infra/argocd-status-rbac.yaml.example`; it is opt-in, and
a project without it sees nothing in `argocd` at all.

**Why this and not the UI.** Projects could already see the *effects* of a sync —
Deployments, Pods and Events in their own namespaces, through Headlamp. What they
could not see is a sync that is **failing**, which is the case that matters: a
stalled sync looks exactly like "nothing has happened yet". Verified by
impersonation before this landed: a project developer got `no` for `get`, `list`
and `watch` on `applications.argoproj.io`.

Exposing the ArgoCD UI behind Dex would also answer it, and `install.md` had
always left that door open. It was not taken because it costs a new public
endpoint, a second authorisation model (`argocd-rbac-cm`, currently empty, with
an unrestricted break-glass `admin` account) and per-project RBAC lines that must
be generated during onboarding or silently drift. The RBAC route reuses the
identity and the tool projects already have.

**The limitation, stated plainly: `kubectl get app -n argocd` is Forbidden.**
Kubernetes RBAC cannot filter a collection, so `resourceNames` does not restrict
`list` — it only permits `get` on named objects. A developer must therefore name
the Application:

```
kubectl get app -n argocd project-infra-<project> \
  -o custom-columns='SYNC:.status.sync.status,HEALTH:.status.health.status'
```

The alternative was granting unscoped `list`, which would expose every project's
Application to every project. A label selector does not help — the filtering is
client-side and the request is refused before it. The same applies in Headlamp,
which lists resources: the Application will not appear in a list view.

**Consequence.** `project-infra` gains `Role` in its
`namespaceResourceWhitelist`, alongside the `RoleBinding` it already had. That
widens the cluster's most privileged AppProject by one kind, which is why the
Role is written per project with explicit `resourceNames` rather than as a shared
ClusterRole: a Role grants no more than the verbs written in it, and only inside
its own namespace. Verbs are `get` and `watch` only — not `patch`, not `delete`,
so a project cannot trigger or abort its own sync. Confirmed by impersonation,
including that another project's team is refused.

**Revisit if** projects ask for the diff view or a self-service sync button.
Those are real arguments for the UI, and the per-project `resourceNames` work
done here is not wasted if it is built.

## 15. The node pool is pinned to one availability zone

**Current.** `infra/aks.bicep` sets `zones: ['1']`. The pool was previously
`['1','2','3']`.

**Why.** Azure managed disks **cannot cross availability zones**. A multi-zone
pool spreads nodes, so a replacement node can land in a different zone from the
one holding the cluster's disks — and every pod with a PVC then becomes
permanently unschedulable, not transiently. `WaitForFirstConsumer` on the
StorageClass is correct and does not prevent this: it places each disk in
whatever zone its pod first landed in, which is right at creation time and
useless once that node is gone.

**Found the hard way, 2026-08-24.** A node-image upgrade replaced the single
zone-1 node with a zone-2 node. All six existing disks (MinIO, Loki, Grafana,
Prometheus, Alertmanager, the Postgres primary) stayed pinned to zone 1, and
their pods sat `Pending` with *"node(s) didn't match PersistentVolume's node
affinity"* until a second node was added back in zone 1. **Scaling *up* is safe;
scaling *down* is destructive**, because Azure chooses which node to remove and
it may be the one whose zone holds the data.

**What is given up.** Nothing that exists today. Zonal redundancy needs more than
one node to mean anything, so a multi-zone pool on a single-node cluster buys
fragility without buying availability. Revisit when the node count grows enough
for zonal HA to be real — and note that at that point stateful workloads need to
be zone-aware or replicated regardless, because the disk constraint does not go
away.

**Which zone does not matter.** `D4s_v6` is offered in all three zones in
`swedencentral` with no restrictions, and pricing is identical. Zone `1` was
chosen only because the cluster's existing disks are already there.

⚠️ **Logical zone numbers are per-subscription aliases, not physical
datacentres.** For this subscription:

| Logical (Bicep, `kubectl`) | Physical (Azure status page) |
|---|---|
| 1 | `swedencentral-az3` |
| 2 | `swedencentral-az1` |
| 3 | `swedencentral-az2` |

This matters when reading an Azure outage notice, which reports **physical**
zones: a reported problem in `az3` is *this cluster's* zone 1. It would also
matter if resources were ever split across subscriptions — matching zone numbers
would not co-locate them. Re-read the live mapping with
`az rest --method get --uri ".../locations?api-version=2022-12-01"` and look at
`availabilityZoneMappings`.

## 16. Node-image upgrades stay automatic, and the shared Postgres has no PDB

**Current.** `nodeOSUpgradeChannel: 'NodeImage'` in `infra/aks.bicep`, and
`enablePDB: false` on the shared CloudNativePG cluster.

**Why automatic, having been burned by it.** On 2026-08-24 an automatic
node-image upgrade left the test cluster's pool in `provisioningState: Failed`,
billing two nodes, and appeared to break SSO. Moving to a manual channel was
implemented and then **rejected**: this platform is maintained by volunteers,
node images ship roughly weekly carrying OS CVE fixes, and a manual step that is
forgotten is worse than an automatic one that occasionally disrupts. **The right
response was to make the disruption survivable, not to move it into a runbook
nobody runs.**

**Why the drain wedged, and why the PDB goes.** CNPG creates a
`PodDisruptionBudget` selecting `cnpg.io/instanceRole: primary` — it protects
whichever pod is currently primary, always exactly one. At `instances: 1` that
makes `disruptionsAllowed` permanently `0`: **no eviction is ever allowed, and
every node drain blocks forever.** AKS retries rather than forcing, emitting
`Eviction blocked by Too Many Requests (usually a pdb): shared-1` — 67 times over
7 minutes in a controlled reproduction. Setting `enablePDB: false` unblocked the
stuck deletion immediately.

Nothing real is given up. A PDB exists to stop Kubernetes evicting the primary
while a replica catches up; with one instance there is no replica, so the
guarantee was already vacuous — it blocked drains without protecting anything.
Postgres still shuts down gracefully (`terminationGracePeriodSeconds: 1800`),
which is what AKS waits for. Upstream CNPG documents `enablePDB: false` as
advisable for non-production clusters.

**`instances: 2` is the alternative fix, not a complement.** It also makes the
PDB satisfiable, and adds real availability — at the cost of a second attached
disk (one of ~6 remaining) and 1Gi more reserved memory. Measured on the test
cluster: actual usage was ~8m CPU and 217Mi per instance, so the cost is the disk
slot rather than compute. Revisit when the node count or the availability
requirement grows.

**This decision depends on [entry 15](#15-the-node-pool-is-pinned-to-one-availability-zone).** Automatic upgrades are only
survivable because the pool is pinned to one zone; a replacement node in another
zone strands every disk-bound workload permanently, and no PDB setting helps.

**Dex keeps its signing keys, so an upgrade no longer logs everyone out.** With
the previous `storage: type: memory`, every Dex restart generated a new signing
key and **invalidated every issued token** — and the resulting `401` was
indistinguishable from a broken authenticator, which produced two wrong
diagnoses. `storage: type: kubernetes` persists the keys as custom resources in
etcd. Verified on the test cluster: the JWKS `kid` was identical across a full
`rollout restart`.

It costs **no PVC and no attached disk** — the store is etcd, reached through the
API server. The chart already shipped the ServiceAccount, the ClusterRole
(`create` on `customresourcedefinitions`) and the namespace Role
(`dex.coreos.com/*`); those permissions were simply unused. Dex creates its own
ten CRDs at startup.

**What it puts in etcd.** Refresh tokens become `refreshtokens.dex.coreos.com`
objects in the `dex` namespace — real credentials in cluster state. Only the Dex
ServiceAccount can read them; a project developer gets `no` (verified by
impersonation), since project `admin` does not reach the `dex` namespace. It also
makes a second Dex replica possible for the first time, because both would share
auth-code state — not done here, but no longer blocked.

**When a `401` still happens**, compare the token's `kid` against Dex's live JWKS
before suspecting anything else ([maintenance.md](maintenance.md)). Keys now
survive restarts, but a token older than a key *rotation* still fails, and that
check distinguishes it from a real fault in seconds.
