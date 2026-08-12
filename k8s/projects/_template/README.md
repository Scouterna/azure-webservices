# Project onboarding template

Copy this directory to `k8s/projects/<project>/` to onboard a project.

Everything here is **infra-owned**: only the infra team commits to this repo. A
project's own workload manifests never live here — see §B.

## A. Namespace + developer access (always)

Layer 1 — the things a project cannot create for itself. The `project-infra`
ApplicationSet syncs this `infra/` directory automatically once committed.

- `namespace-dev.yaml`, `namespace-prod.yaml` — the project's namespace(s).
- `developer-rbac.yaml.example` → rename to `developer-rbac.yaml`. Binds a
  GitHub team (or user) to `admin` within the project's namespaces.
- `database.yaml.example` → rename to `database.yaml` if the project needs a
  database on the shared PostgreSQL server.
- `sealedsecret-*.yaml` — committed sealed secrets, if any.

Only filenames matching the ApplicationSet's `include:` glob are applied. **A
file that matches nothing is ignored silently** — no error, no event.

No ResourceQuota or LimitRange is applied by default — the platform monitors
usage and only intervenes reactively (see
`k8s/infra-manifest/cluster-infra/monitor-limits/`).

## B. The project's workload — two routes, and it is the project's choice

The project owns its namespaces, so it owns what runs in them. There are exactly
two routes, and **neither puts the project's workload manifests in this repo**.

### B1. By hand (the default, and a fine end state)

`kubectl` / `helm` with the project's own credentials, in its own namespaces. No
infra request, nothing committed anywhere. Most **dev** environments stay here
permanently.

### B2. The project's own GitOps repo

The project keeps a GitOps repo it controls; infra wires it up **once** and then
never touches it again. From then on the project commits to its own repo and
ArgoCD syncs it.

Infra registers it with **two files in this repo**:

1. `k8s/projects/<project>/gitops.yaml` — copy `gitops.yaml.example` here and
   fill in the repo URL, revision and environments. The `project-gitops`
   ApplicationSet turns it into one Application per environment.
2. `k8s/argocd/projects/<project>.yaml` — copy
   `k8s/argocd/projects/_project-gitops.yaml.example`. This is the project's own
   AppProject, and it is **the security boundary**: it names only that project's
   repo and only its namespaces.

**What a project can deploy from its own repo is deliberately limited to
workload kinds.** It cannot create `RoleBinding`, `Role`, `ServiceAccount`,
`Secret`, `ExternalSecret`, CNPG databases, or ArgoCD `Application`s — that last
one because an `Application` with `project: infra` would be a one-file escape to
cluster-admin. Anything from that list is an infra request, delivered through
`infra/` in this repo.

Moving from B1 to B2 is safe: if the by-hand install matches what the repo says,
ArgoCD **adopts** the running release without restarting anything.

See `docs/onboarding.md` for the full flow and `docs/argocd.md` for operating it.
