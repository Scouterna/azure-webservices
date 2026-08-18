# ArgoCD lathund — driving ArgoCD with kubectl

This cluster runs ArgoCD with **no ingress and no GUI login** by choice (see
[install.md](install.md) → *ArgoCD access*). Everything below therefore uses
`kubectl` against the `Application` CRs, which works over the normal OIDC
kubeconfig:

- **no ArgoCD login, no port-forward, no shared `admin` password**, and
- the action is attributable to **you**, because the API server sees your
  identity.

`argocd` CLI equivalents are listed for reference; they need a login and are not
the default path here.

> Everything that *configures* ArgoCD belongs in Git. The commands here are
> **operations** — refresh, sync, inspect — which have no Git representation.
> Anything that changes desired state is a commit, not a kubectl patch.

---

## Reading state

```bash
export KUBECONFIG=$PWD/.kube-webservices     # or your OIDC kubeconfig
kubectl get app -n argocd                    # everything, one line each
```

`app` is the short name for `applications.argoproj.io`. Add `-w` to watch.

**Only what needs attention** — the single most useful command:

```bash
kubectl get app -n argocd --no-headers | awk '$2!="Synced" || $3!="Healthy"'
```

**With the synced revision** (which commit each app is actually on):

```bash
kubectl get app -n argocd -o custom-columns=\
'NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.status.sync.revision'
```

A `REV` of `<none>` is normal for an app whose source is a Helm chart rather than
this repo — there is no Git commit to report.

**Which resources inside an app are drifting:**

```bash
kubectl get app -n argocd <app> \
  -o jsonpath='{range .status.resources[?(@.status=="OutOfSync")]}{.kind}/{.name}{"\n"}{end}'
```

**Why an app is unhappy** — conditions carry the real error:

```bash
kubectl get app -n argocd <app> \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
```

**The last sync attempt and its outcome:**

```bash
kubectl get app -n argocd <app> \
  -o jsonpath='{.status.operationState.phase}: {.status.operationState.message}{"\n"}'
```

**ApplicationSets** (the generators, not the generated apps):

```bash
kubectl get applicationset -n argocd
kubectl describe applicationset -n argocd project-infra   # generator errors land here
```

---

## Refresh — re-read Git without syncing

ArgoCD polls Git every ~3 minutes. To make it look **now**:

```bash
kubectl annotate app -n argocd <app> argocd.argoproj.io/refresh=normal --overwrite
```

**Hard refresh** additionally discards the cached rendered manifests. Use it when
the Git commit did not change but the *rendering* should — a re-pushed Helm chart
tag, a changed `ConfigMap` the chart reads, or a repo-server cache you suspect:

```bash
kubectl annotate app -n argocd <app> argocd.argoproj.io/refresh=hard --overwrite
```

Two things about this annotation:

- The controller **consumes it** — it disappears from the object within seconds.
  That is success, not failure. `--overwrite` is required because the second
  invocation would otherwise collide with the value still being written.
- **Refresh is not sync.** It updates `status.sync` to tell you *whether* you are
  OutOfSync. It never applies anything. An app with `automated:` will then sync
  on its own; an app without it will sit there reporting the drift forever.

---

## Sync — actually apply

Most apps here are `automated: {selfHeal: true}` and never need this. You need it
when an app is **manual-sync** (no `automated:`, as project dev apps are), or when
**automated retries are exhausted** (`retryCount` reaches 5 — the app then stops
retrying and a refresh will *not* restart it).

```bash
kubectl patch app -n argocd <app> --type merge \
  -p '{"operation":{"initiatedBy":{"username":"'"$USER"'"},"sync":{}}}'
```

**This drops the app's `syncOptions`.** ArgoCD reads sync options from the
*operation*, not from `spec.syncPolicy.syncOptions` — an operation with an empty
`sync: {}` gets none, regardless of what the Application declares. Concretely:
an app with `CreateNamespace=true` will fail with `namespaces "<ns>" not found`
on a hand-triggered sync against a namespace that doesn't exist yet, even though
the same app syncs it fine when `selfHeal` triggers automatically. Carry the
options through explicitly:

```bash
OPTS=$(kubectl get app -n argocd <app> -o jsonpath='{.spec.syncPolicy.syncOptions}')
OPTS=${OPTS:-[]}          # an app with no syncOptions yields an empty string, not []
kubectl patch app -n argocd <app> --type merge \
  -p '{"operation":{"initiatedBy":{"username":"'"$USER"'"},"sync":{"syncOptions":'"$OPTS"'}}}'
```

The `${OPTS:-[]}` is not optional. `jsonpath` returns a JSON array when the field
is set, but an **empty string** when it is absent — which would splice into
`"syncOptions":}` and be rejected as malformed. Project dev apps are manual-sync
and often have no `syncOptions` at all, so this is the common case here, not the
edge case.

Then check the result — the patch returns immediately and tells you nothing:

```bash
kubectl get app -n argocd <app> \
  -o jsonpath='{.status.operationState.phase}: {.status.operationState.message}{"\n"}'
```

`Succeeded`, `Running`, `Failed` or `Error`. `argocd app sync <app>` does the same
with progress streaming, if you have a login.

**Omit `revision` on a multi-source app.** With several `sources[]` — an OCI chart
plus this repo for `$values` — a single `revision` is applied to the wrong source.
Leave it out and each source syncs to its own `targetRevision`.

**A sync discards hand edits.** An app on manual sync lets you change the release
in the cluster and keeps that drift; the next sync reapplies Git wholesale and
throws it away. Capture it first:

```bash
helm get values <release> -n <namespace>
```

Fold that into the values file, commit, *then* sync — the handover step in
[onboarding.md](onboarding.md) §C.

---

## Common situations

| Symptom | What it means | What to do |
|---|---|---|
| `OutOfSync` / `Healthy`, app has `automated` | Usually a controller writing `status` back (ESO `ExternalSecret`, CNPG `Cluster`, a webhook `caBundle`). Cosmetic. | Nothing. Confirm with the drifting-resources command above. |
| `OutOfSync` on a **manual-sync** app | Correct and expected — that is the whole point of manual sync. | Sync when you mean to, after capturing hand edits. |
| `Unknown` / `Unknown` | The spec was **rejected**; nothing was rendered. | Read `.status.conditions` — usually `InvalidSpecError` about `sourceRepos`. |
| `Synced` but the change is not live | The rendered output did not change, or you synced a different source. | Hard refresh, then re-check `status.sync.revision`. |
| Stuck `Progressing` for a long time | A resource never reaches Healthy (pod crash-looping, PVC Pending, cert not issued). | Inspect the underlying resources; ArgoCD is reporting, not causing. |
| App deleted itself / will not delete | The `resources-finalizer.argocd.argoproj.io` finalizer blocks removal until child resources are gone. | Investigate the children first; removing the finalizer orphans them. |

**`InvalidSpecError: application repo … is not permitted in project`** is the most
common bootstrap failure. The `AppProject` must list the source in `sourceRepos`,
and the matching is fussy — see `k8s/projects/_template/README.md` §B2 for the
`**` and OCI rules. The app sits at `Unknown/Unknown` until it is fixed.

---

## What NOT to do with kubectl

**Do not `kubectl patch` a resource an ArgoCD app manages** to test a change. With
`selfHeal: true` it is reverted within seconds, and you will draw conclusions from
an object that keeps resetting. Change Git and sync, or turn off `automated` first.

**Do not edit an `Application` in the cluster** if it is generated by an
ApplicationSet or an app-of-apps — the parent overwrites it. Edit the file in Git.

**Do not `kubectl delete app`** to force a rebuild unless you mean it: with
`prune: true` the deletion cascades to everything the app manages.

---

## Where each piece of config lives

| To change | Edit | Applied by |
|---|---|---|
| A common service | `k8s/argocd/infra-apps/<svc>.yaml` + its values under `k8s/infra-manifest/` | `infra-root` |
| An AppProject | `k8s/argocd/projects/*.yaml` | `argocd-projects` (wave -1) |
| A project's namespace / RBAC / DB | `k8s/projects/<project>/infra/` | `project-infra` ApplicationSet |
| A project's own AppProject (its repo + namespaces + what it may deploy) | `k8s/argocd/projects/<project>.yaml` | `argocd-projects` (wave -1) |
| Registering a project's own GitOps repo | `k8s/projects/<project>/gitops.yaml` | `project-gitops` ApplicationSet |
| A project's workload itself | **the project's own repo** — not this one | the generated `<project>-<env>` Application |
| ArgoCD itself | pinned `install.yaml` URL in [install.md](install.md) §10 | hand-applied, once |

A file in a directory nothing watches is **silently ignored** — no error, no event.
If a commit seems to do nothing, check it is in a path one of the above actually
syncs, and that it matches any `include:` glob on that Application.
