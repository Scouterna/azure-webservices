# Reactive namespace limits (documented, NOT applied by default)

The platform's stance is **monitor, don't constrain**: projects own their
namespaces and no ResourceQuota / LimitRange is applied by default. The infra
group watches per-namespace usage (dashboards + soft alerts) and only
intervenes if one namespace starves others on the shared node(s).

When that happens, apply one of the templates here to the *specific* misbehaving
namespace — a reactive, targeted guardrail, never a cluster-wide default. Edit
`NAMESPACE` and the numbers to fit, then `kubectl apply -f`.

- `limitrange.yaml` — default + max CPU/memory per container/pod, so a single
  runaway pod can't request the whole node.
- `resourcequota.yaml` — a hard ceiling on the namespace's total
  requests/limits and object counts.

Remove them again once the project is back in line — they are a temporary
corrective, not a permanent policy.
