# Namespace isolation

Why the cluster stops a project namespace from reaching the node, and what the
two controls that do it deliberately do *not* cover.

## The problem both controls address

A project developer holds ClusterRole `admin` in their own namespaces. That
bounds what they can **address** — it does not, on its own, bound what they can
**reach**. The cluster is single-node, so the node runs ArgoCD, External
Secrets, the Sealed Secrets private key, MinIO's root credentials and the shared
PostgreSQL alongside every project. A workload that gets to the node gets to all
of it.

Two paths led out of a namespace. They close each other's gap, and neither is
sufficient alone.

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

## How the two interlock

`baseline` forbids `hostNetwork`, which matters for the network policy:
host-network pods share the node's Cilium identity rather than getting their own
endpoint, so **no pod-level policy selects them**. Without Pod Security, a
project could opt out of the IMDS deny simply by asking for host networking.

## Known limits

- **Infra namespaces are not PSA-labelled.** A host-networked pod in an infra
  namespace still shares the node identity and is not selected by the IMDS
  policy. Infra-controlled, so low risk — but it is not covered.
- **The WireServer at `168.63.129.16` is not blocked.** It also serves platform
  DNS and health probes, so denying it needs its own analysis.
- **IPv6 is not addressed** — Azure IMDS is IPv4-only.
- Out of scope here, each its own change: scoping the `ClusterSecretStore` with
  `spec.conditions`, `disableLocalAccounts`, API-server audit retention, and an
  Alertmanager receiver.
