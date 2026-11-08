# proj-dj26

Demokratijamboree 2026: [Scoutin 2](https://github.com/Scouterna/scoutin-2),
the check-in kiosks, badge printing and admin, at
https://dj26-scoutin.app.ws.scouterna.net/.

One environment, `proj-dj26-prod`. The workload, its sealed secrets and the
event's config live in the **private** repo
[Scouterna/dj26-infra](https://github.com/Scouterna/dj26-infra), which ArgoCD
syncs from `main` (automated, self-heal) over a read-only deploy key. Private
because the badge carries unreleased brand assets.

## What is here

| File | What |
|---|---|
| `gitops.yaml` | registers dj26-infra's `k8s/prod` with ArgoCD |
| `infra/namespace-prod.yaml` | the namespace, Pod Security `baseline` |
| `infra/developer-rbac.yaml` | GitHub team `DJ26` → `view` in prod. Direct members only: Dex lists no parent or child teams |
| `infra/argocd-status-rbac.yaml` | lets the team read `project-infra-proj-dj26` and `proj-dj26-prod` |
| `infra/database.yaml` | the `proj-dj26-db` Secret for the shared PostgreSQL, from `scripts/new-project-db.sh` |
| `infra/sealedsecret-argocd-repo.yaml` | the deploy key for dj26-infra |

Elsewhere in this repo: the AppProject `k8s/argocd/projects/proj-dj26.yaml`,
and the role and database `k8s/infra-manifest/postgres/databases/proj-dj26.yaml`.

## Rules for this directory

- **Infra-owned.** Only the infra team commits here. DJ26's workload manifests
  never live here; they go in dj26-infra.
- **Filenames are load-bearing.** The `project-infra` ApplicationSet applies only
  names on its `include` list (`k8s/argocd/projects-root/projectset.yaml`):
  `namespace-*.yaml`, `developer-rbac.yaml`, `database.yaml`,
  `sealedsecret-*.yaml` and a few more. **Any other file is ignored silently.**
- **dj26-infra may deploy workload kinds only** (its AppProject's whitelist). A
  RoleBinding, ServiceAccount, plain Secret, ExternalSecret or database for DJ26
  is an infra request, delivered as a file in `infra/` here.
- **Removing a file deletes nothing**: prune is off, so a live namespace and its
  data are only ever removed deliberately (docs/onboarding.md, "Removing a
  project").

How any of this is done — access, databases, deploy keys — is in
[docs/onboarding.md](../../../docs/onboarding.md).
