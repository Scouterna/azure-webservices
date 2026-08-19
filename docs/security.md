# Namespace isolation

Why the cluster stops a project namespace from reaching the node and the shared
Key Vault, and what the three controls that do it deliberately do *not* cover.

## The problem these controls address

A project developer holds ClusterRole `admin` in their own namespaces. That
bounds what they can **address** — it does not, on its own, bound what they can
**reach**. The cluster is single-node, so the node runs ArgoCD, External
Secrets, the Sealed Secrets private key, MinIO's root credentials and the shared
PostgreSQL alongside every project. A workload that gets to the node gets to all
of it.

Three paths led out of a namespace: two to the node (§1, §2, which close each
other's gap and neither of which is sufficient alone), and one straight to the
vault (§3) that neither of the first two touches.

## 1. Egress to IMDS is denied

`k8s/infra-manifest/cluster-infra/networkpolicy/deny-imds.yaml`

The Azure Instance Metadata Service at `169.254.169.254` answers unauthenticated
HTTP from **any** pod on the node, and issues tokens for the *node's* kubelet
identity — an identity that belongs to no namespace. Cilium was enabled as the
policy dataplane at build time but the cluster shipped with no policies, so this
was open to every workload.

**Why `kube-system` is the only carve-out.** Checked rather than assumed: the AKS
system components and the Key Vault CSI provider legitimately use the node
identity, and they all run there. Nothing outside it needs IMDS — External
Secrets and Velero authenticate with Workload Identity (a projected federated
token against `login.microsoftonline.com`), CloudNativePG's backups use an
explicit storage-account key from a Secret, and everything else talks only
in-cluster.

A side effect worth having: this removes the silent `DefaultAzureCredential`
fallback to the node identity, so a broken federated credential now fails
loudly instead of quietly escalating.

**Why a deny rule rather than an allow-list.** In Cilium, an endpoint selected by
any *allow* egress rule flips to default-deny egress. A cluster-wide allow-list
would have to enumerate every legitimate destination of every pod, and one
omission is an outage. A deny rule cannot break traffic it does not mention.

> **`enableDefaultDeny: {egress: false, ingress: false}` is load-bearing.**
> Without it the selected endpoints — every namespace except `kube-system` —
> flip to default-deny egress and the targeted deny becomes a cluster-wide
> outage. The manifest carries a one-line warning; this is the reasoning behind
> it.

**Why the selector is `NotIn [kube-system]`** rather than a list of project
namespaces: a namespace created later is then denied by default. A new infra
component that needs the node identity fails visibly at deploy time, instead of
a new project quietly inheriting the escalation path.

**Verify enforcement, do not assume it.** `Synced` says the object exists, not
that traffic is dropped — the app is green either way. The probe is in
[install.md](install.md) §11 ("IMDS is blocked").

## 2. Project namespaces enforce baseline Pod Security

`k8s/projects/_template/infra/namespace-*.yaml`

`admin` permits any `securityContext`, and with no Pod Security Admission labels
and no admission controller, a privileged or `hostPath` pod was simply accepted.
Both namespace templates now set `enforce: baseline`, which rejects exactly that
class: privileged containers, host namespaces (`hostNetwork`, `hostPID`,
`hostIPC`), `hostPath` volumes, `hostPort`, and capabilities beyond the default
set.

**Why `baseline` and not `restricted`.** `baseline` is what closes the escape.
`restricted` additionally forbids running as root, which breaks a large share of
upstream images for no gain against this finding. `restricted` is set as `warn`
and `audit` instead, so a project sees what a later tightening would ask for
while nothing breaks today.

**Why `enforce-version` is pinned.** Admission behaviour should not change under
running workloads because the control plane moved. The cost is that the pin does
not follow an AKS upgrade — see [maintenance.md](maintenance.md) under AKS
upgrades, which says to bump it as a separate commit after the cluster. The
`warn`/`audit` labels are deliberately left unpinned, so the gap between the two
is visible in the meantime.

**The labels are the whole mechanism, and PSA is silent without them.** A
namespace committed without them is simply unprotected: no error, nothing in the
cluster to notice. `.github/workflows/checks.yml` therefore asserts that every
project namespace carries an `enforce` level (`baseline` or `restricted`, never
`privileged`) and a pinned version.

Projects cannot remove them: `admin` carries no permission on the Namespace
object, and the `project-infra` ApplicationSet runs with `selfHeal: true`.

## How §1 and §2 interlock

`baseline` forbids `hostNetwork`, which matters for the network policy:
host-network pods share the node's Cilium identity rather than getting their own
endpoint, so **no pod-level policy selects them**. Without Pod Security, a
project could opt out of the IMDS deny simply by asking for host networking.

## 3. The shared Key Vault is reachable only where it is needed

`k8s/infra-manifest/external-secrets/values.yaml`,
`k8s/infra-manifest/external-secrets/clustersecretstore.yaml`

Neither control above touches this path, because it needs no pod at all — just
one API call. External Secrets authenticates to the vault with **its own**
Workload Identity, holding `Key Vault Secrets User` across the whole vault. An
`ExternalSecret` names a key; ESO fetches it and writes a Secret into the
`ExternalSecret`'s namespace. So whoever can create an `ExternalSecret` can read
**any** secret in the vault, into a namespace they control — the Sealed Secrets
private key (which decrypts every `SealedSecret` in this public repo), MinIO's
root credentials, the backup storage-account key, the Dex and Grafana OAuth
client secrets, and every other project's PostgreSQL password.

Two independent things had to be true for that to be reachable from a project
namespace, and both were:

**ESO folded write access into the built-in `admin` role.** Its chart ships a
`external-secrets-edit` ClusterRole labelled
`rbac.authorization.k8s.io/aggregate-to-admin`, carrying `create`/`update`/
`patch` on `externalsecrets`. Kubernetes aggregation is effectively transitive —
`view`'s rules flow into `edit`, `edit`'s into `admin` — so labelling for either
`edit` or `admin` reaches `admin`. Developers are bound to `admin`, so they held
`externalsecrets: create`. The values file now sets `rbac.aggregateToAdmin: false`
and `rbac.aggregateToEdit: false`.

That ClusterRole granted more than reading. The same verbs covered `PushSecret`
and `ClusterPushSecret`, which write *into* the vault — so the exposure was
tamper and destroy, not only disclosure — and the 18 `generators.external-secrets.io`
kinds, including `Webhook`, which makes the ESO controller issue an arbitrary
HTTP request and capture the response into a Secret. Dropping the aggregation
labels removes all 23 resources at once, not just `externalsecrets`. Worth
knowing before anyone re-enables `aggregateToEdit` to grant read access —
`aggregateToView` is the flag for that, and it is already on.

`rbac.aggregateToView` is deliberately left **on**: read-only `get`/`watch`/`list`
on the `ExternalSecret` object lets a developer see whether their own secret
synced. It exposes the *key name* in the spec, never the value — and the
materialised Secret is in their own namespace, which `admin` could always read.

**The store was usable from every namespace.** A `ClusterSecretStore` with no
`spec.conditions` is available cluster-wide. It now lists the six infra
namespaces that consume it (`dex`, `headlamp`, `minio`, `monitoring`, `postgres`,
`sealed-secrets`) plus a label selector, `scouterna.se/keyvault-access: "true"`,
for project namespaces.

**Why project namespaces are in scope at all.** A project with a database on the
shared server gets its password from the vault — `PROJECT-db` in
`k8s/projects/<project>/infra/database.yaml`, which is infra-committed, not
developer-written. Those namespaces must therefore be allowed, which is why the
RBAC half above is the load-bearing fix and the conditions are defence in depth.

**Why the label is opt-in per environment.** A namespace with no database gets no
vault access at all, and granting it is a visible one-line change next to the
`database.yaml` that needs it.

Every way of getting this wrong ends in the same place — a stalled
`ExternalSecret`, invisible until someone looks, and nothing alerts on it yet — so
`.github/workflows/checks.yml` asserts the whole chain rather than one link of it:
that a store named `azure-kv` exists at all (every `ExternalSecret` here
references it *by name*, so a rename breaks all of them), that it has
`conditions`, that those conditions carry a selector matching the label, and that
every namespace consuming it is permitted by one clause or the other.

## Known limits

- **Adding a namespace to the store grants it the *whole* vault.** There is no
  per-key scoping in a shared `ClusterSecretStore`: the limit is which namespaces
  may use it, not which keys they may read. Real per-project scoping needs a
  separate identity per project with Azure RBAC assigned at **secret** scope, and
  a `SecretStore` per project to use it. Until then, treat membership of
  `conditions` as "trusted with every secret in the vault", and keep the vault's
  own role assignments minimal (`maintenance.md` makes the same point).
- **`admin` still permits reading Secrets in its own namespace.** That is by
  design — they are the project's own credentials — but it means a materialised
  vault secret is readable by anyone with `admin` there. Put only what a
  namespace needs into it.
- **Infra namespaces are not PSA-labelled.** A host-networked pod in an infra
  namespace still shares the node identity and is not selected by the IMDS
  policy. Infra-controlled, so low risk — but it is not covered.
- **The WireServer at `168.63.129.16` is not blocked.** It also serves platform
  DNS and health probes, so denying it needs its own analysis.
- **IPv6 is not addressed** — Azure IMDS is IPv4-only.
- **Cluster-admin access is a separate document.** The static admin certificate,
  why it cannot be disabled on this cluster, and what constrains it instead are in
  [cluster-access.md](cluster-access.md).
- **Out of scope here**: an Alertmanager receiver, so none of the above raises an
  alarm when it stops working. API-server *mutations* are now audited off-cluster
  ([decisions.md](decisions.md) entry 9) — but **reads are not**, in Kubernetes or in
  Key Vault, so a secret being read leaves no trace either way.
