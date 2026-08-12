# webservices cluster — documentation

| Doc | What it covers |
|-----|----------------|
| [install.md](install.md) | The full build runbook, from empty subscription to running cluster — one continuous session, dependency-ordered (prerequisites → provision → cluster-derived wiring → ArgoCD). Non-obvious pitfalls called out inline. |
| [onboarding.md](onboarding.md) | How a project gets namespace(s) and developer access, and the two routes for its own workload: by hand, or from the project's own GitOps repo. |
| [argocd.md](argocd.md) | Lathund for driving ArgoCD with `kubectl` — no CLI, no GUI: read state, refresh, sync, and what each symptom means. |
| [maintenance.md](maintenance.md) | Version pins, upgrade cadences, and how to keep the platform current. |
| [postgres.md](postgres.md) | The shared PostgreSQL design: why one server, what isolation it gives, and when a project should get its own instance. |
| [certificates.md](certificates.md) | How TLS is issued (HTTP-01 today), and the **proposal** to add DNS-01 per zone for wildcards — with the credential question that decides it. |

## What the cluster is

A shared Scouterna Kubernetes cluster (AKS, `swedencentral`), budget-sized
(single node, manual scaling), portable-by-intent (few Azure-specific pieces).
The infra group owns the cluster + common services via ArgoCD + Helm; projects
own their namespaces. See the [top-level README](../README.md) for the full
design rationale.
