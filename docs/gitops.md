# How GitOps is wired

What actually happens between a commit landing on `main` and something changing
in the cluster. The [README's repository layout](../README.md#repository-layout)
says what lives where; this says how it runs, and why it is ordered the way it is.

Nothing here is applied by hand. There is no `helm install` and no `kubectl apply`
in normal operation — ArgoCD reconciles everything from `main`, and the bootstrap
exception is noted at the end.

## The one-paragraph version

One root Application watches `k8s/argocd/infra-apps/` and creates an Application
for every file it finds there — the app-of-apps pattern. Each of those manages one
common service. Two ApplicationSets do the same job for projects: one for the
namespaces and access infra grants a project, one for a project's own GitOps repo.
Everything is ordered by sync waves, because several services cannot start before
another has created the thing they depend on.

## Layer 1 — the root, and the common services

```
k8s/argocd/infra-root-app.yaml        applied ONCE at bootstrap, then self-managing
        │  path: k8s/argocd/infra-apps, recurse: true
        ▼
k8s/argocd/infra-apps/*.yaml          22 Applications, one per common service
        │  each points at a chart and/or
        ▼
k8s/infra-manifest/<service>/         Helm values and raw manifests
```

**Adding a common service is one file.** Drop an `Application` into
`k8s/argocd/infra-apps/`, commit, and the root picks it up on its next
reconcile — there is no second place to register it.

The Applications mostly reference an upstream chart by version plus a values file
from this repo (ArgoCD's multi-source pattern), so upgrading a service is a version
bump in one file. A few use a plain directory of manifests instead, where no chart
fits: `cluster-infra` is the clearest example.

### Sync waves — the ordering, and why

An `argocd.argoproj.io/sync-wave` annotation on each Application sets the order.
Lower waves reconcile first. This matters because roughly half the platform
depends on something another service created — a CRD, a StorageClass, a bucket, a
Secret.

| Wave | Applications | Why here |
|---|---|---|
| **-1** | `argocd-projects` | The AppProjects themselves. Every other Application names one, and an Application whose project does not exist cannot sync. |
| **0** | `cluster-infra`, `cert-manager`, `external-secrets`, `gateway-api-crds` | Things others build on: StorageClasses, ClusterIssuers, and the CRDs plus admission webhooks that later waves reference. External Secrets is deliberately a full wave ahead of anything using an `ExternalSecret` kind. |
| **1** | `traefik`, `minio`, `minio-buckets`, `external-secrets-config`, `cloudnative-pg`, `barman-cloud-plugin`, `sealed-secrets-key` | Needs wave 0. MinIO needs a StorageClass; `external-secrets-config` needs the operator's CRDs to exist before its `ClusterSecretStore` will validate. |
| **2** | `monitoring`, `postgres`, `dex`, `sealed-secrets` | Needs wave 1. Monitoring needs the MinIO buckets (Loki chunks and the Prometheus Thanos sidecar) and the Secrets that `external-secrets-config` materialised. |
| **3** | `headlamp`, `thanos`, `postgres-databases` | Needs wave 2. Headlamp needs Dex to authenticate against; Thanos needs Prometheus writing blocks; the databases need the server. |
| **4** | `velero`, `dashboards`, `governance` | Needs everything else. `governance` carries the alerting rules, which need the monitoring stack from wave 2 to exist before they mean anything. |

**Waves order the *start* of a sync, not its completion.** ArgoCD moves to the
next wave when the previous wave's resources report healthy, but a resource can
report healthy before what it created is usable. Where that has bitten, the
Application's own header comment says so — those comments are the authoritative
per-service note, and they are worth reading before changing a wave.

## Layer 2 — projects

Two ApplicationSets, doing deliberately different jobs. The split matters: one
side is infra-controlled, the other is project-controlled, and they get different
trust.

### `projectset.yaml` — what infra grants a project

```
k8s/projects/<project>/infra/         committed by INFRA only
        │  discovered by a git directory generator
        ▼
Application  project-infra-<project>  in AppProject `project-infra`
```

It syncs an **explicit list of filenames**, not the directory:

```
namespace.yaml, namespace-*.yaml, developer-rbac.yaml, database.yaml, sealedsecret-*.yaml
```

**A file matching none of that list is ignored silently** — ArgoCD still reports
`Synced`/`Healthy`, because from its point of view there is nothing to apply. If
something you committed never appears in the cluster, check the filename against
that list first. Adding a new kind of infra manifest means extending the glob in
`projectset.yaml`.

`prune: false` here is deliberate: deleting a project's directory does **not**
delete its live namespace and data. Retiring a project is a deliberate act, not a
side effect of a commit.

### `gitops-appset.yaml` — a project's own workload

```
k8s/projects/<project>/gitops.yaml    infra commits this pointer once
        │  matrix generator: project × environments
        ▼
Application  <project>-<env>          in the project's OWN AppProject
        │  source: the PROJECT's repo
        ▼
Scouterna/<project>-gitops
```

This is the self-service path. Infra wires it up once; after that the project
commits to its own repo and ArgoCD reconciles it, with nobody on the infra side
reviewing what it deploys.

**That is why the AppProject is the security boundary**, and why
`_project-gitops.yaml.example` says so in its first lines. It pins the source repo
to exactly one URL, the destinations to that project's namespaces, allows no
cluster-scoped resources at all, and lists the workload kinds it permits — with
`ServiceAccount`, `RoleBinding`, `Secret`, `ExternalSecret` and `argoproj.io/*`
excluded as named escalation paths. See [decisions.md](decisions.md) entry 12 for
why this design was chosen over the alternative, and entry 8 for what it does
**not** cover: the AppProject bounds the GitOps route only, and a project
deploying by hand with `kubectl` is bounded by Kubernetes RBAC instead.

A project's workload does not have to go through ArgoCD at all — running it by
hand with `kubectl` or `helm` is a supported route. See
[onboarding.md](onboarding.md) §C.

## What happens when you commit

1. You push to `main`. Nothing has changed in the cluster yet.
2. ArgoCD notices on its next poll. The affected Application goes `OutOfSync`.
   **Polling is the only trigger here** — no repository webhook is configured, so
   a push is never pushed *to* the cluster. The interval is ArgoCD's
   `timeout.reconciliation`, left at its 180s default (`argocd-cm` sets no
   override), so expect up to about three minutes. To not wait, force a refresh:
   [argocd.md](argocd.md).
3. With `automated` sync — which the infra Applications have — it applies the
   change and returns to `Synced`. With `selfHeal: true` it will also revert
   anything changed in the cluster by hand.
4. `Healthy` then means the resulting resources report healthy, which is a
   separate question from whether the sync worked.

**`Synced` compares against the revision the Application last recorded, not the
tip of `main`.** An Application sitting on an older commit can report
`Synced`/`Healthy` while missing your change entirely. When something has not
appeared, check the revision before anything else:

```bash
kubectl -n argocd get app <app> -o jsonpath='{.status.sync.revision}{"\n"}'
git rev-parse origin/main
```

[argocd.md](argocd.md) covers driving this with `kubectl` — reading state,
forcing a refresh, triggering a sync, and what each symptom means.

## The bootstrap exception

`infra-root-app.yaml` and the AppProjects in `k8s/argocd/projects/` are applied
once with `kubectl apply` during the initial build, because ArgoCD cannot sync an
Application whose AppProject does not yet exist. From then on the
`argocd-projects` Application adopts and owns those objects, and further changes
reach the cluster by commit like everything else. [install.md](install.md) has the
exact step.

## Where to look when something is wrong

| Symptom | Look at |
|---|---|
| Committed a file to a project's `infra/`, nothing happened | The filename, against the include glob in `projectset.yaml` |
| Application is `Synced`/`Healthy` but the change is missing | `.status.sync.revision` versus `origin/main` |
| A new common service never appeared | Whether the file is in `k8s/argocd/infra-apps/` and parses |
| A service starts before its dependency is ready | Its `sync-wave`, and the header comment in its Application |
| A project cannot deploy some kind | Its AppProject's `namespaceResourceWhitelist` — the exclusions are deliberate |
