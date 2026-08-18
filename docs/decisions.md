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
