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

**What this does not give.** Attribution for the local admin certificate is still
Azure-side only — requests arrive as `masterclient` whatever the audit log records
(see [cluster-access.md](cluster-access.md)). And **Key Vault reads are not
audited**: no diagnostic setting exists on the vault, so there is no record of which
secrets were read from the cluster's root of trust. Given that this category cannot
record Kubernetes reads either, that is the notable remaining gap — it is the half
of the original finding this change does not close, and it stays listed in
[maintenance.md](maintenance.md). **Alerting is Azure-side, not Alertmanager.** In-cluster alerting is still missing
(see [maintenance.md](maintenance.md)), but this workspace never depended on it:
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
