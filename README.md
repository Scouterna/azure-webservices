# Webservices v2

A shared Kubernetes platform for Swedish Scouting (Scouterna) — one cluster in
Azure that many projects use, over many years.

The infrastructure group owns the cluster and a set of common services (ingress,
monitoring, logging, object storage, databases, secrets). Projects get their own
namespaces and run whatever they like inside them. Everything here is
Infrastructure-as-Code: the cluster in **Bicep**, everything on top in **Helm +
ArgoCD**, so the whole platform can be torn down and rebuilt from this repo.

---

## Design principles

- **One cluster, budget-first.** A single, modestly-sized cluster. Scaling is a
  deliberate, reviewed change (edit a parameter, redeploy) — never automatic.
- **Projects own their namespaces.** No resource quotas by default. The platform
  *observes* usage and intervenes reactively only if one project starves others.
- **Portable by intent.** As few Azure-specific pieces as possible, so the
  cluster could in principle move to another cloud or distro. The Azure surface
  is small and clearly marked (see [Portability](#portability)).
- **GitOps.** The infra group manages the common services declaratively via
  ArgoCD. Projects *may* register with ArgoCD too, but it is optional.
- **Reproducible.** The runbooks in [`docs/`](docs/) rebuild the whole platform
  from scratch. This has been proven end-to-end (full teardown + rebuild).

---

## Architecture at a glance

```
                        Internet
                           |
                 +---------v---------+     Azure LoadBalancer (public IP)
                 |      Traefik      |     ingress + TLS
                 +---------+---------+      (cert-manager / Let's Encrypt)
                           |
          +----------------+----------------+
          |                                 |
   +------v-------+                 +--------v--------+
   |   project    |   ...projects   |     common      |  owned by the infra
   |  namespaces  |                 |    services     |  group, managed by
   +--------------+                 +-----------------+  ArgoCD

   common services:  Traefik . cert-manager . MinIO (object storage) .
   kube-prometheus-stack (Prometheus/Grafana/Alertmanager) . Loki (logs) .
   Thanos (long-term metrics) . External Secrets Operator (Key Vault) .
   CloudNativePG (PostgreSQL) . Headlamp (web UI)
```

The cluster is **AKS** in **Sweden Central**: a single `Standard_D4s_v6` node
(4 vCPU / 16 GB, manual scaling), Kubernetes 1.36.2, **Cilium** eBPF dataplane
enforcing NetworkPolicy, Workload Identity + OIDC, and the Key Vault CSI add-on.
See [`infra/aks.bicep`](infra/aks.bicep).

What the cluster actually enforces today — one cluster-wide egress deny, baseline
Pod Security on project namespaces, and no default-deny baseline yet — is in
[docs/security.md](docs/security.md), with the reasoning behind each choice in
[docs/decisions.md](docs/decisions.md).

Storage is in-cluster and portable: **MinIO** for S3-compatible object storage
(backs Loki, Thanos, and backups) and **CloudNativePG** for PostgreSQL — no Azure
data PaaS. Persistent volumes use a cheap StandardSSD StorageClass by default,
with a Premium class available opt-in.

### Common services

| Service | What it does | Chart |
|---|---|---|
| **cluster-infra** | StorageClasses, cert-manager ClusterIssuers, cluster-wide NetworkPolicy | raw manifests |
| **cert-manager** | TLS certificates (Let's Encrypt) | `cert-manager` v1.21.0 |
| **Traefik** | Ingress controller (default class) + LoadBalancer | `traefik` 41.0.2 |
| **MinIO** | S3-compatible object storage | `minio` 5.4.0 |
| **CloudNativePG** | PostgreSQL operator + the shared PostgreSQL server | `cloudnative-pg` 0.29.0 |
| **External Secrets** | Sync secrets from Azure Key Vault (Workload Identity) | `external-secrets` 2.8.0 |
| **Sealed Secrets** | Commit-safe secrets projects can self-serve | `sealed-secrets` 2.19.1 |
| **monitoring** | Prometheus + Grafana + Alertmanager | `kube-prometheus-stack` 87.19.2 |
| **Loki + Alloy** | Log aggregation and collection | `loki` 18.5.4, `alloy` 1.11.0 |
| **Thanos** | Long-term / HA metrics (MinIO-backed) | `thanos` 1.24.0 |
| **Dex** | GitHub SSO for Headlamp and `kubectl` | `dex` 0.24.1 |
| **Headlamp** | Kubernetes web UI (GitHub SSO via Dex) | raw manifests, image `v0.41.0` |
| **Velero** | Namespace + PVC backups to Azure Blob | `velero` 12.1.0 |
| **governance** | Per-namespace dashboard + soft-threshold alerts | raw manifests |

Charts come from their upstream repositories; only the **values** live here (the
ArgoCD multi-source pattern), so upgrades are a version bump.

> These versions drift the moment a chart is bumped. The pins that actually
> govern the cluster are `targetRevision` in
> [`k8s/argocd/infra-apps/`](k8s/argocd/infra-apps/) and `kubernetesVersion` in
> [`infra/env/webservices.bicepparam`](infra/env/webservices.bicepparam) —
> **check there during an incident**, not here. `docs/maintenance.md` tracks the
> upgrade cadence.

---

## Repository layout

```
infra/                     Bicep — the only Azure-specific layer
  aks.bicep                the cluster
  keyvault.bicep           durable Key Vault (separate, long-lived RG)
  main.bicep               orchestrator
  env/webservices.bicepparam  cluster params (no secrets — committed)

k8s/
  argocd/
    projects/              AppProjects: infra, project-infra, one per project
    projects-root/         ApplicationSets: project infra/, and project GitOps repos
    infra-root-app.yaml    app-of-apps root (recurses infra-apps/)
    infra-apps/            one ArgoCD Application per common service (by sync-wave)
  infra-manifest/          Helm values + raw manifests for the common services
  projects/_template/      copy this to onboard a project (namespaces, RBAC, database)

docs/                      build + onboarding runbooks (start here to build the cluster)
```

Onboarding a new common service is one file: drop an `Application` into
`k8s/argocd/infra-apps/` and commit — the app-of-apps root picks it up.

---

## Building the cluster

The whole build is one runbook: **[docs/install.md](docs/install.md)** — from an
empty subscription to a running cluster, as a single continuous shell session. It
captures every step and gotcha, ordered by dependency: prerequisites that need no
cluster first (quota, GitHub OAuth app, Key Vault, identities, secrets, backup
storage), then provisioning, then the cluster-derived wiring, then bootstrapping
ArgoCD.

The common services are installed and managed **only** by ArgoCD — no manual
`helm install`. `k8s/argocd/infra-root-app.yaml` manages everything from `main`.

> **Secrets & IDs are never committed.** This is a public repo. Kubeconfigs and
> secret material are gitignored; the cluster's subscription is selected out of
> band (`az account set`), not stored here. The Bicep param file holds only
> cluster shape (no identifiers), so it is committed.

---

## Using the platform (projects)

Projects are onboarded via [docs/onboarding.md](docs/onboarding.md). In short:

- A project gets one or more **namespaces** (e.g. `myapp-dev`, `myapp-prod`).
- Developers sign in with their **GitHub identity via Dex SSO**, in Headlamp and
  with `kubectl` alike — ClusterRole `admin` inside their namespaces, and no grant
  outside them. Namespaces enforce the `baseline` Pod Security Standard, so
  `admin` stops at the node rather than reaching it. Access is granted by
  committing a RoleBinding that names a GitHub team; there are **no ServiceAccount
  tokens to hand out**, and revoking access is removing someone from the team —
  effective on the next login, with an already-issued session lasting until its
  token expires (24h).
- The project's **own workload** runs one of two ways, its choice: **by hand**
  (`kubectl`/`helm` with its own credentials), or from **its own GitOps repo**,
  which infra wires into ArgoCD once. Workload manifests never live in this repo.
  Moving from the first to the second is a no-op — ArgoCD adopts the running
  release without restarting it.
- A project's ArgoCD scope is its **own AppProject**, naming only its repo and
  its namespaces, and permitting workload kinds only — not RBAC, ServiceAccounts,
  Secrets or ArgoCD Applications. Those stay infra-granted. It bounds the **GitOps
  path**; a project deploying by hand is bounded instead by Kubernetes RBAC and
  Pod Security, which is why those matter as much as the whitelist.
- Projects needing centralized secrets get them from the shared Key Vault as
  native Kubernetes Secrets — no CSI mount dance. Infra commits the
  `ExternalSecret`, because creating one reads the vault; see
  [docs/decisions.md](docs/decisions.md) entry 6.

### Governance by observation

No quotas are imposed by default. The infra group watches a per-namespace
resource dashboard and soft-threshold alerts (a namespace requesting a large
share of the cluster, or a PVC filling up). If a namespace starves others, a
reactive `LimitRange` / `ResourceQuota` is applied to *that* namespace only, as
a temporary corrective — see
[`k8s/infra-manifest/cluster-infra/monitor-limits/`](k8s/infra-manifest/cluster-infra/monitor-limits/).

---

## Portability

Almost everything is standard Kubernetes and moves unchanged. The Azure-specific
touchpoints are few and isolated:

| Touchpoint | Where | On another cloud/distro |
|---|---|---|
| AKS control plane | `infra/aks.bicep` | Replace the Bicep layer; all of `k8s/` moves as-is |
| `disk.csi.azure.com` StorageClass | `cluster-infra/storageclass/` | Change the provisioner; keep the class names |
| LoadBalancer annotations | `traefik/values.yaml` | Provider's LB annotations, or MetalLB |
| Secrets backend (Key Vault) | External Secrets `ClusterSecretStore` | Swap the store (Vault/AWS/GCP); `ExternalSecret`s unchanged |

In-cluster MinIO + CloudNativePG mean **no Azure data PaaS**. The residual Azure
surface is one Bicep template, one StorageClass string, a couple of LB
annotations, and one secret-store object.

---

## Status

The cluster and every common service have been built and validated end-to-end,
including a full **teardown + rebuild from the docs** and a full **ArgoCD
bring-up from Git**. Backups (Velero → MinIO, plus CloudNativePG's own backups)
are the next planned addition.
