# Working in this repo

Orientation for AI coding agents (and new maintainers). This file is about *how
to work here*; the documentation in [`docs/`](docs/) is about *what the platform
is*. Where the two disagree, `docs/` wins.

## What this repo is

The complete definition of **one live AKS cluster** (`webservices-v2`, Sweden
Central) that hosts Swedish Scouting projects: Azure resources in **Bicep**
(`infra/`), everything on top in **Helm values + ArgoCD** (`k8s/`), runbooks in
`docs/`. Read [README.md](README.md) once before your first change.

Three things follow from that, and they shape almost every rule below:

1. **`main` is the live cluster.** ArgoCD syncs `k8s/` from `main` continuously.
   A merged commit is a change to a running system, not a proposal.
2. **The repo is public.** Anyone can read it, including the mistakes.
3. **The maintainers are volunteers.** Optimise for "a stranger can follow this
   in a year", not for cleverness.

## Read before you act

Ordered by how often it saves a wasted change:

| Before you… | Read |
|---|---|
| reopen a design question ("why not X?") | [docs/decisions.md](docs/decisions.md) — it records what was chosen *and what was rejected* |
| change what ArgoCD applies | [docs/gitops.md](docs/gitops.md) |
| onboard a project or grant access | [docs/onboarding.md](docs/onboarding.md) (the `/onboard-team` command is a summary, not a replacement) |
| touch versions or upgrade anything | [docs/maintenance.md](docs/maintenance.md) |
| reason about isolation, RBAC or PSA | [docs/security.md](docs/security.md), [docs/cluster-access.md](docs/cluster-access.md) |
| debug a certificate | [docs/certificates.md](docs/certificates.md) |
| debug ArgoCD itself | [docs/argocd.md](docs/argocd.md) |

**Version pins in `README.md` and `docs/` drift.** The pins that actually govern
the cluster are `targetRevision` in [`k8s/argocd/infra-apps/`](k8s/argocd/infra-apps/)
and `kubernetesVersion` in [`infra/env/webservices.bicepparam`](infra/env/webservices.bicepparam).
During an incident, read those — not the tables.

## Hard rules

**Never commit secrets, identifiers or credentials.** Public repo. Kubeconfigs,
`*.key`, `*.pem`, `.env` and security-review notes are gitignored; that is a
safety net, not the control. The control is you checking the diff.

**Everything is a commit.** The common services are installed and managed *only*
by ArgoCD. Do not `helm install`, and do not `kubectl apply` cluster state by
hand — ArgoCD's selfHeal reverts it mid-debug and you will chase a ghost. Use
`kubectl` to *read*.

**Never hand out ServiceAccount tokens.** Developer access is a committed
RoleBinding naming a GitHub team, resolved through Dex SSO. AKS caps SA tokens at
24h, and the workaround (a `kubernetes.io/service-account-token` Secret) creates
a non-expiring credential that survives revoking the binding. See
[docs/onboarding.md](docs/onboarding.md).

**Ask before committing or pushing.** Branch and stage freely; let a human
approve the commit. `/k8s/`, `/infra/`, `/monitoring/` and `/.github/` are
CODEOWNERS-protected and merge through a PR.

## Synced ≠ working

This is the single most expensive lesson in this repo's history. ArgoCD reports
**Synced/Healthy** for a great many broken states, because it only knows whether
the manifest was applied:

- An unfilled `<PLACEHOLDER>` reaches Helm as a literal string. Velero
  authenticates as a client-id called `<VELERO_CLIENT_ID>` and fails at runtime.
- A file whose name doesn't match the ApplicationSet's `include:` glob is
  **ignored silently** — no error, no event.
- A namespace committed without a `pod-security.kubernetes.io/enforce` label is
  simply unprotected.
- A RoleBinding naming a wrong identity string looks correct and grants nothing.
- An immutable field changed on a StorageClass makes ArgoCD retry forever while
  showing only `OutOfSync`.

So: **assert, don't eyeball.** After a change, verify the *effect* against the
live cluster, not the sync status. For RBAC that means
`kubectl auth can-i ... --as-group=...`; for a secret, that the target Secret
exists; for an issuer, that the Certificate is `Ready`.

## CI, and the placeholder trap

[`.github/workflows/checks.yml`](.github/workflows/checks.yml) runs on every PR:

- **placeholders** — `scripts/check-placeholders.sh --expect-filled`
- **manifests** — every YAML under `k8s/` parses
- **pod-security** — every project namespace pins an allowed PSA level
- **secret-store-scope** — the `azure-kv` ClusterSecretStore is scoped, and every
  namespace consuming it is permitted by it
- **decisions-pointers** — every "entry N" reference into `docs/decisions.md`
  resolves and is gap-free

> **The trap:** `main` now carries the live install's *filled-in* values, so CI
> checks `--expect-filled`. But the opt-in pre-commit hook
> (`scripts/install-hooks.sh`) checks the opposite direction,
> `--expect-template`, from when this repo was an unfilled template. If you
> enable the hooks on `main`, staging a `k8s/` manifest will be refused. The hook
> is not installed by default — leave it that way unless you are working a
> template branch.

When you add a CI check, make sure it fails for the right reason: run it against
a deliberately broken tree once. Several checks here exist because something
passed while being wrong.

## Conventions

**Comments in config are terse.** In Bicep, Helm values and YAML, a comment says
*what* and the non-obvious *why-not-the-obvious-thing* — in a line or two.
Rationale belongs in `docs/decisions.md`, not inline. This is a standing house
rule.

**Pointers into `docs/decisions.md` are by entry number**, written as
"decisions.md entry N", and CI enforces that they resolve. If you renumber an
entry, CI will find the dangling pointers — do not hand-hunt them.

**Naming says the job, not the product.** The Loki/Thanos object store is
`telemetry-store`; it happens to run MinIO. The name "MinIO" is reserved for a
future project-facing store.

**Layout at a glance:**

```
infra/                       Bicep — the only Azure-specific layer
                             main.bicep orchestrates; the durable resources
                             (keyvault, backup-storage, loganalytics, alerts)
                             deploy standalone and survive a cluster teardown
k8s/argocd/infra-apps/       one Application per common service (sync-wave ordered)
k8s/argocd/projects/         AppProjects — the ArgoCD-side blast radius
k8s/argocd/projects-root/    ApplicationSets: project infra, and project GitOps repos
k8s/infra-manifest/<svc>/    Helm values + raw manifests for one common service
k8s/projects/_template/      copy this to onboard a project
docs/                        runbooks — start at docs/README.md
scripts/                     check-placeholders.sh, new-project-db.sh, hooks
```

Adding a common service is one file: an `Application` in `k8s/argocd/infra-apps/`.
The app-of-apps root recurses the directory.

## Habits that pay off here

- **Search with `rg -e '<pattern>'`.** Always `-e`. A flag-shaped pattern
  silently returns the wrong result, and `-r` is `--replace`, not recursive.
- **Negative results are the dangerous ones.** "I searched and found nothing"
  is a claim to double-check before acting on it.
- **Say what the blast radius is** before a change that touches the live cluster,
  and prefer `letsencrypt-staging` / a dev namespace to prove a mechanism first.
- **Don't relay bot review comments — adjudicate them.** Check the claim against
  the cluster or the code, then say whether it is right.
