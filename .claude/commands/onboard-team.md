# Onboard a project or developer to the webservices cluster

Onboard a project (namespaces + database) or grant a developer access, so they
can manage their own namespace(s) via Headlamp or `kubectl`.

**The authoritative source is [docs/onboarding.md](../../docs/onboarding.md).**
Read it before acting — this file is a summary of where things live and the
traps, not a replacement runbook. Where the two disagree, the doc wins.

## The access model (read this first)

Developers authenticate with their **GitHub identity via Dex SSO**. There are
**no ServiceAccount tokens to hand out** — do not create any.

Access is granted by **committing a RoleBinding**, not by running `kubectl`:
`k8s/projects/<project>/infra/developer-rbac.yaml`, which binds a GitHub **team**
(or a single user) to a ClusterRole within the project's namespaces. The
`project-infra` ApplicationSet applies it.

> **Never fall back to `kubectl create serviceaccount` + `kubectl create token`.**
> AKS caps those tokens at **24h**, and that limit is precisely *why* this cluster
> uses Dex — an earlier design handed out year-long tokens and was replaced. The
> workaround (a `kubernetes.io/service-account-token` Secret) creates a
> **non-expiring credential that survives revoking the binding**, and must not be
> used. Revoking SSO access is removing someone from the GitHub team.

## Cluster context

- Cluster: `webservices-v2` (Azure AKS, swedencentral)
- Kubernetes UI: https://headlamp.wsinfra.scouterna.net (GitHub SSO)
- Ingress: Traefik (class `traefik`); TLS via cert-manager `letsencrypt-prod`
- DNS: `*.wsinfra.scouterna.net` → the Traefik LoadBalancer (managed externally)

## What to ask before starting

**Onboarding a project** (docs/onboarding.md §A):
1. **Project name** — becomes the directory `k8s/projects/<project>/` and the
   namespace prefix.
2. **Environments** — dev + prod is the default; one namespace or an added
   staging both need the template trimmed (§A step 2).
3. **Does it need a database?** — a database on the shared PostgreSQL server
   (§"Add a database"), one per environment.
4. **Will it run its own GitOps repo?** — if so, its repo URL and one path per
   environment (§C2). Otherwise it installs by hand and nothing more is needed.

**Granting a developer access** (§B):
1. **Which GitHub team** (preferred) or which GitHub login.
2. **Which namespaces**, and **`admin` or `view`**.

## Steps

Everything is a **commit** — no hand-applied `kubectl`.

1. **Project + namespaces:** copy `k8s/projects/_template/` to
   `k8s/projects/<project>/` and substitute the name. Follow §A exactly; it has
   the file-count check that catches a nested-copy mistake.
2. **Developer access:** rename `infra/developer-rbac.yaml.example` to
   `infra/developer-rbac.yaml` and set the team or user. §B has the exact
   identity strings — they differ per system, are case-sensitive, and **fail
   silently** when wrong (see §"Verifying identity strings").
3. **Database (optional):** §"Add a database" — a Key Vault password per
   environment, plus the infra-side database manifest.
4. **Their own GitOps repo (optional):** §C2 — `gitops.yaml` plus a per-project
   AppProject copied from
   `k8s/argocd/projects/_project-gitops.yaml.example`.

Only filenames matching the ApplicationSet's `include:` glob are applied. **A
file that matches nothing is ignored silently** — no error, no event.

## Verify

```bash
kubectl get ns -l scouterna.se/project=<project>
kubectl auth can-i create deployments -n <project>-dev \
  --as=anyone --as-group='aks:jwt:Scouterna:<Team Display Name>'
```

The impersonation check is the real test — a RoleBinding that exists but names
the wrong identity string looks correct and grants nothing.

## Revoking access

Remove the developer from the GitHub team, or remove them from
`developer-rbac.yaml` and commit. There is no token to invalidate.
