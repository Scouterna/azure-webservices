# Onboarding a project

Projects own their namespace(s) and manage resources inside them however they
like. The platform does not set quotas by default — it monitors usage (see
[governance by observation](#governance-by-observation-what-the-infra-group-watches)
below) and intervenes only reactively.

Onboarding has two layers, split by who is allowed to do what:

- **Layer 1 — infra-owned resources** a project *cannot* create for itself:
  its namespace(s), developer access (RBAC), and any shared services like a
  database. These live in `k8s/projects/<project>/infra/` and are applied
  **automatically by ArgoCD** — the infra team just commits the files.
- **Layer 2 — the project's own workload** (its Deployment, Ingress, …). The
  project runs this itself (with `kubectl`/`helm` as their GitHub identity, see
  [developer access](#b-developer-access-github-sso)), and *optionally* registers
  it with ArgoCD. Infra does not touch it.

The whole point of Layer 1 being GitOps: on a long-lived shared cluster with
maintainers coming and going, Git is the source of truth. What's committed is
what's running; ArgoCD self-heals drift; a successor onboards by reading the
repo, not by hoping a runbook is current.

## How Layer 1 is applied (no manual kubectl)

An ApplicationSet (`k8s/argocd/projects-root/projectset.yaml`) watches
`k8s/projects/*/infra/`. For every project directory it finds, it generates an
ArgoCD `Application` that syncs that project's `infra/` folder under the
`project-infra` AppProject. So **committing a project's `infra/` files is what
deploys them** — there is no `kubectl apply` step.

It syncs only the files matching the `include` list in `projectset.yaml` —
today `namespace.yaml` / `namespace-*.yaml`, `developer-rbac.yaml`,
`database.yaml`, and `sealedsecret-*.yaml` (that list is the source of truth;
anything else is ignored silently). The `*.example` files shipped by the
template are ignored until you copy them to their real name. `_template/` itself
is excluded.

## A. Create the project and its namespace(s)

1. **Copy the template and name it.** Set the project name once; everything below
   uses `$PROJECT`. This copies `k8s/projects/_template/` to
   `k8s/projects/$PROJECT/` and replaces the `PROJECT` placeholder everywhere it
   appears — including the `.example` files, so they are ready when you activate
   them later.

   > **Naming rule — stricter than a Kubernetes namespace.** Lowercase letters,
   > digits and **single** hyphens, starting and ending alphanumeric, ≤58 chars.
   > **No consecutive hyphens:** `foo--bar` is a legal namespace but Azure
   > rejects it as a blob container name, so a project named that way onboards
   > fine and then fails later at `scripts/onboard-cnpg-backup.sh`. The name also
   > becomes database roles and backup container names — renaming afterwards
   > means recreating them.

   ```bash
   export PROJECT=<project name>           # the only thing to set
   cd "$(git rev-parse --show-toplevel)"   # works from any subdirectory

   cp -r k8s/projects/_template "k8s/projects/$PROJECT"
   rm -f "k8s/projects/$PROJECT/.gitkeep"
   grep -rlZ PROJECT "k8s/projects/$PROJECT/" | xargs -0 sed -i "s/PROJECT/$PROJECT/g"
   ```

   **Check it before moving on** — the file list should be 6 files, all under
   `k8s/projects/$PROJECT/`, and no `PROJECT` may remain:

   ```bash
   find "k8s/projects/$PROJECT" -type f | sort
   grep -rn PROJECT "k8s/projects/$PROJECT/" || echo "no PROJECT placeholders left — good"
   git status --short
   ```

   > If it went wrong — pasted into the wrong repo, or `$PROJECT` already existed
   > so `cp` nested a `_template/` copy inside it — nothing is committed yet.
   > Remove it and start over:
   > ```bash
   > rm -rf "k8s/projects/$PROJECT"
   > git rm -r --cached --ignore-unmatch -q "k8s/projects/$PROJECT"   # if already staged
   > git status --short                                               # must be clean
   > ```
   > The nested case is the quiet one: the placeholder check still passes (the
   > `sed` rewrote the nested copy too), so the **file list** is what catches it.

   (`GITHUB_LOGIN` in `developer-rbac.yaml.example` is a **separate** placeholder
   and is deliberately left alone — it's filled per developer in
   [section B](#b-developer-access-github-sso).)

2. **Choose the namespace(s).** The template ships `namespace-dev.yaml` and
   `namespace-prod.yaml` as the common case, but the set is **flexible** — the
   ApplicationSet syncs `infra/namespace.yaml` **and** any
   `infra/namespace-*.yaml`. Add or delete files to match what the project needs:

   - **dev + prod (default):** keep both files as-is — nothing to do.
   - **one namespace only:** collapse to a single `namespace.yaml` named just
     `$PROJECT` (no `-dev` suffix, no `env` label):
     ```bash
     cd "$(git rev-parse --show-toplevel)/k8s/projects/$PROJECT"

     rm infra/namespace-prod.yaml
     mv infra/namespace-dev.yaml infra/namespace.yaml
     sed -i -e "s/^  name: $PROJECT-dev\$/  name: $PROJECT/" \
            -e '/scouterna\.se\/env:/d' infra/namespace.yaml

     cat infra/namespace.yaml
     cd "$(git rev-parse --show-toplevel)"
     ```
     If the project later registers its own GitOps repo, trim `gitops.yaml`'s
     `environments` list to match — an entry naming a namespace that does not
     exist produces an Application that can never sync.
   - **add staging:** copy the namespace file and edit the copy:
     ```bash
     sed "s/dev/staging/g" infra/namespace-dev.yaml > infra/namespace-staging.yaml
     ```

   > Filenames must be `namespace.yaml` or `namespace-<something>.yaml` — that is
   > what the ApplicationSet's include glob matches.

3. **Commit** — ArgoCD creates the namespace(s):
   ```bash
   git add "k8s/projects/$PROJECT"
   git commit -m "Onboard $PROJECT"
   git push
   ```
   Then confirm (may take a minute for ArgoCD to sync):
   ```bash
   kubectl get ns -l "scouterna.se/project=$PROJECT"
   kubectl get application -n argocd | grep "$PROJECT"
   ```

4. **No ResourceQuota / LimitRange is applied.** The project owns the namespace.

## B. Developer access (GitHub SSO)

Developers authenticate with their **GitHub identity** via SSO (Dex fronts
GitHub; the cluster's API server trusts Dex). A developer *is* their GitHub
login — there is **no ServiceAccount and no token to hand out**. Two things gate
access:

1. **Membership in the Scouterna GitHub org** — Dex rejects anyone outside it, so
   a developer must be an org member before they can log in at all.
2. **A RoleBinding** the infra team commits, binding the developer's OIDC
   identity into the namespace(s) they should manage.

The OIDC username is `aks:jwt:<github-login>` (the login, lowercased, with an
`aks:jwt:` prefix). **Infra-team members** are handled separately: membership in
the `Webservices Infra` GitHub team grants cluster-admin cluster-wide — they do
**not** need per-project RoleBindings.

### Grant access

In the project's directory, copy `developer-rbac.yaml.example` to
`developer-rbac.yaml` — dropping the `.example` suffix is what makes the
ApplicationSet sync it:

```bash
cd "$(git rev-parse --show-toplevel)/k8s/projects/$PROJECT"
cp infra/developer-rbac.yaml.example infra/developer-rbac.yaml
```

Then keep the block(s) you need and fill in the names. The example ships **both**
subject kinds; choose per your case (and mix freely — one file can hold both):

- **A GitHub team** (`kind: Group`, `"aks:jwt:<org>:<Team Display Name>"`) —
  **recommended for real teams.** Infra commits the binding **once**; thereafter
  membership is managed in GitHub: add someone to the team → they get access on
  next login; remove them → access is gone. No cluster change, no commit either
  way. Keeps developer churn out of the repo entirely.
- **A single developer** (`kind: User`, `"aks:jwt:<github-login>"`, lowercased) —
  for one-off / individual access.

In both cases: add one RoleBinding **per namespace** the team/developer should
access (a dev/prod project needs a binding in each), and use ClusterRole `admin`
(full control within the namespace) or `view` (read-only).

**Commit** — ArgoCD creates the RoleBinding(s):

```bash
cd "$(git rev-parse --show-toplevel)"          # the cp above left you in the project dir

git add "k8s/projects/$PROJECT/infra/developer-rbac.yaml"
git status --short                             # only that file should be staged
git diff --cached                              # check the identity strings before pushing

git commit -m "Grant developer access to $PROJECT"
git push
```

The `.example` file stays in place and is never synced — only the renamed
`developer-rbac.yaml` is. Stage it by name rather than `git add -A`, so an
unrelated edit elsewhere in the tree does not travel with it.

Confirm once ArgoCD has synced (a minute or so):

```bash
kubectl get rolebinding -n <namespace>

# individual:
kubectl auth can-i create deployments -n <namespace> --as="aks:jwt:<github-login>"
# team (impersonate the group):
kubectl auth can-i create deployments -n <namespace> \
  --as=anyone --as-group="aks:jwt:<org>:<Team Display Name>"
```

> **Read the exact group string from the system that emits it** — never
> reconstruct it by rule. See [Verifying identity strings](#verifying-identity-strings).

> The file stays a **`.example`** in the template so ArgoCD never syncs the
> unfilled placeholders. Only the real, renamed `developer-rbac.yaml` is applied.

### How a developer logs in

**Headlamp (web UI):** browse to `https://headlamp.wsinfra.scouterna.net`, click
**Sign in**, authenticate with GitHub. They see only the namespaces their
RoleBindings grant.

**kubectl / helm (CLI):** one-time setup, then it's transparent:

1. Install the `kubectl oidc-login` plugin ([int128/kubelogin][kubelogin] — note
   this is **not** the Azure `kubelogin`):
   ```bash
   kubectl krew install oidc-login          # if you have krew
   ```
   No krew? Download the release binary for your OS from the [kubelogin
   releases][kubelogin] and put it on your `PATH` as `kubectl-oidc_login`
   (kubectl discovers `kubectl-<name>` binaries as the `kubectl <name>` plugin).
2. Get the shared **OIDC kubeconfig** from the infra team (or the repo). It
   contains no secrets — the cluster address, the public CA, and an `exec` block
   that runs `kubectl oidc-login` against Dex. It is **identical for every
   developer**; identity is established at login time.
3. Run any `kubectl` command. The first one opens a browser for GitHub login;
   the token is then cached and silently refreshed (a browser login roughly
   weekly). Example:
   ```bash
   kubectl get pods -n <namespace>          # works within granted namespaces
   ```

[kubelogin]: https://github.com/int128/kubelogin

### Grafana (metrics and logs)

Grafana uses the same GitHub login, but a **separate** permission model from
Headlamp/kubectl — it is not driven by your RoleBindings.

| GitHub team | Grafana role | Can |
|---|---|---|
| `Scouterna/Webservices Infra` | Admin | Everything, incl. datasources and users |
| Any other Scouterna member | Viewer | Read dashboards |

Membership of the **Scouterna org** is all that is required to log in. There is
no Editor tier: infra dashboards live in Git under
`k8s/infra-manifest/monitoring/dashboards/` and are loaded by the Grafana
sidecar, so dashboards are added by pull request, not authored in the UI.

Two consequences worth knowing:

- **Roles are re-derived from GitHub on every login.** Changing someone's role in
  the Grafana UI works until they next sign in, then reverts. Team membership is
  the source of truth; the UI role dropdown is effectively read-only.
- **A role limits what you can *do*, not what you can *see*.** Grafana queries a
  single shared Prometheus and Loki, so any Viewer can read any namespace's
  metrics and logs — including through Explore, with no dashboard involved.
  Kubernetes RBAC does **not** apply to these queries. Per-project data
  isolation is a separate, unimplemented design; until it exists, treat
  everything in Grafana as visible to all of Scouterna, and keep genuinely
  sensitive values out of logs.

### Verifying identity strings

Three places match on a GitHub-derived identity string, and **each uses a
different format**. All three fail the same way: a wrong string is not an error,
it simply never matches, so the user silently gets less access than intended.

| Where | Format | Example |
|---|---|---|
| Kubernetes RBAC (Headlamp, kubectl) | `aks:jwt:<Org>:<Team Display Name>` — display name verbatim, spaces included | `aks:jwt:Scouterna:WSJ27 Crew` |
| Grafana `role_attribute_path` | `@<Org>/<team-slug>` — org keeps its casing, slug lowercased and hyphenated | `@Scouterna/webservices-infra` |
| Dex `groups` claim | `<Org>:<Team Display Name>` | `Scouterna:Webservices Infra` |

Note the traps: RBAC wants the **display name**, Grafana wants the **slug**, and
the org keeps its capital `S` in all of them while the slug does not. Swedish
characters are transliterated in slugs (`E-tjänster` → `e-tjanster`). JMESPath
`contains()` in Grafana is case-sensitive.

Never derive these by applying the rules above — print the real value:

```bash
# Grafana: the exact strings Grafana compares against, for YOUR account
gh api /user/teams --paginate --jq '.[] | "@\(.organization.login)/\(.slug)"'

# All team slugs and display names in the org
gh api /orgs/Scouterna/teams --paginate --jq '.[] | "\(.slug)\t\(.name)"'

# Kubernetes RBAC / Dex: from a real login by a team member
kubectl -n dex logs deploy/dex | grep "login successful"
```

Then confirm the binding actually grants what you expect:

```bash
kubectl auth can-i create deployments -n <namespace> \
  --as=anyone --as-group="aks:jwt:<Org>:<Team Display Name>"
```

For Grafana, the only real test is a fresh sign-out and sign-in: the role is
computed at login, so an existing session keeps its old role, and a running
Grafana keeps its old config until the pod restarts.

## C. The project's own workload — by hand, or from your own GitOps repo

Layer 2 belongs to the project. There are exactly **two routes**, and neither
puts your workload manifests in the infra repo.

### C1. By hand (the default)

`helm install` / `kubectl apply` with your own credentials, in your own
namespaces. You own them, so no infra request is needed and nothing has to be
committed anywhere. Iterate freely.

For most **dev** environments this is the end state, and that is fine.

### C2. Your own GitOps repo

Keep a GitOps repo **you** control. Infra wires it into ArgoCD **once**; after
that you commit to your own repo and ArgoCD syncs it — no infra involvement in
day-to-day changes, and no handing files over.

#### What to give infra

Ask infra for a registration, giving them:

1. **the repo URL** (and branch) — public needs nothing further; a **private**
   repo also needs an ArgoCD repository credential, and the credential's URL
   **scheme must match** the repo URL (an `https://` repo needs an HTTPS/token
   credential, not an SSH deploy key);
2. **one path per environment** inside that repo, e.g. `k8s/dev` and `k8s/prod`;
3. whether each environment should be **automated** (ArgoCD applies and
   self-heals — the cluster always matches Git) or **manual** (ArgoCD reports
   drift but changes nothing until a deliberate sync). Prod is normally
   automated; dev is often manual so you can keep hand-editing.

Infra commits two small files and you are live. You never touch the infra repo.

#### Moving from by-hand (C1) to GitOps

**Moving from C1 to C2 is a no-op if the repo matches what is running.** Same
release name, same namespace, same values → ArgoCD **adopts** the running
release: `Synced` without restarting anything. Verify nothing was recreated,
rather than trusting the word "Synced":

```bash
kubectl get app -n argocd <app>                       # Synced / Healthy
kubectl get rs -n <namespace>                         # no new ReplicaSet
kubectl get pods -n <namespace>                       # AGE unchanged, RESTARTS 0
```

If pods restart, the committed manifests differ from what was running — diff
them (`helm get values <release> -n <namespace>`) before committing, not after.

> **On a manual environment, a sync DISCARDS hand edits** — it reapplies Git
> wholesale. Capture anything you want to keep first. See
> [argocd.md](argocd.md).

#### What your repo may deploy

Your AppProject names **only your repo** and **only your namespaces**, so you
cannot deploy from another project's repo or into another project's namespace.
Within your namespaces you may create workload kinds: `Deployment`,
`StatefulSet`, `DaemonSet`, `Job`, `CronJob`, `Service`, `Ingress`,
`NetworkPolicy`, `ConfigMap`, `PersistentVolumeClaim`,
`HorizontalPodAutoscaler`, `PodDisruptionBudget`, `ServiceMonitor`, and Traefik
`IngressRoute`/`Middleware`.

> **`IngressRoute` cannot cross namespaces.** Traefik runs with
> `allowCrossNamespace: false`, so a route may only reference Services and
> Middlewares in its own namespace — you cannot route to (or be routed to by)
> another project. A cross-namespace `namespace:` field in a route is rejected
> by Traefik, not by ArgoCD, so it shows as a route that never takes effect
> rather than a sync error. If you genuinely need this, talk to infra rather
> than working around it.

**Deliberately excluded**, because a commit in your repo is not reviewed by
infra:

| Kind | Why |
|---|---|
| `RoleBinding`, `Role` | would let a commit grant itself `admin`/`cluster-admin` |
| `ServiceAccount` | mints an identity, and a token with it |
| `Secret`, `SealedSecret` | credentials stay infra-granted; also keeps plaintext out of your Git |
| `ExternalSecret` | would read any Key Vault secret ESO's identity can reach |
| ArgoCD `Application` | one with `project: infra` is a complete escape to cluster-admin |
| CNPG `Cluster`/`Database` | databases are Layer 1, on the shared server |

Anything on that list is an infra request, delivered through
`k8s/projects/<project>/infra/` in the infra repo — which only infra can commit.
That is the same boundary as before; it is now enforced by the AppProject rather
than by infra reviewing every change.

## Secrets

Three paths, pick by how the secret should be owned:

| Need | Path | Infra involvement |
|---|---|---|
| Central custody / rotation, must outlive the cluster | **Key Vault + ESO** | infra sets each value in the vault |
| Commit-safe, in Git, self-service, survives rebuild | **Sealed Secrets** | one-time key setup only |
| Project-owned, kept out of Git, re-created by hand | **plain imperative Secret** | none |

### Centralized secrets (via Key Vault — needs the infra team)

Use this when the secret must **outlive the cluster** (a rebuild recreates every
namespace from Git, so an in-namespace Secret is gone), or must be custodied
centrally (rotated in one place, not pasted around). The value lives in the
shared Key Vault; ESO (External Secrets Operator) reconciles it into a native
`Secret` in the project's namespace — no CSI mount, no pod required, refreshed on
an interval.

**What the infra team does** (the project cannot — Key Vault write access and the
`ClusterSecretStore` are infra-owned):

1. **Put the value in Key Vault.** Pick a clear, unique key name (convention:
   `<project>-<purpose>`, e.g. `proj-scoutid-smtp-password`):
   ```bash
   az keyvault secret set --vault-name $KEY_VAULT_NAME \
     --name proj-scoutid-smtp-password --value "$THE_SECRET"
   ```
   That's the whole infra-side action. The shared `azure-kv` `ClusterSecretStore`
   already exists and ESO already has `Key Vault Secrets User` on the vault, so no
   per-secret identity or store wiring is needed.

**What the project does** (self-service, in its `infra/` dir or its own manifests
— it just needs an `ExternalSecret`, which the `project-infra` scope allows):

2. Add an `ExternalSecret` referencing that key. It names the shared store and the
   KV key, and ESO writes a native `Secret` the workload consumes normally:
   ```yaml
   apiVersion: external-secrets.io/v1
   kind: ExternalSecret
   metadata:
     name: smtp
     namespace: proj-scoutid
   spec:
     refreshInterval: 24h
     secretStoreRef:
       name: azure-kv           # the shared store — do not create your own
       kind: ClusterSecretStore
     target:
       name: smtp               # the Secret ESO creates in this namespace
       creationPolicy: Owner
     data:
       - secretKey: password    # key inside the resulting Secret
         remoteRef:
           key: proj-scoutid-smtp-password   # the Key Vault secret name
   ```
   (See `k8s/infra-manifest/external-secrets/*.yaml` for infra's own examples, and
   the `ExternalSecret` in `_template/infra/database.yaml.example`.)

> **Isolation caveat (be honest about it):** the shared `azure-kv` store is
> cluster-scoped, so an `ExternalSecret` in *any* namespace can reference *any* KV
> key — there is no per-namespace ACL. Keys are not secret-by-name, but don't rely
> on obscurity. If a project needs a vault only it can read, ask the infra team for
> a **dedicated Key Vault + a namespaced `SecretStore`** instead of the shared one.

### Commit-safe self-service secrets (Sealed Secrets — no infra team)

Use this when you want the secret **in Git** (so ArgoCD applies it declaratively
and it survives a rebuild) but you do **not** want to file an infra ticket for
each value. The cluster runs the **Sealed Secrets** controller: you encrypt a
`Secret` with the `kubeseal` CLI against the controller's public key, commit the
resulting `SealedSecret` (which only the in-cluster controller can decrypt), and
the controller turns it back into a native `Secret` in your namespace. Safe to
commit even to the public repo; fully self-service per secret.

```bash
# One-time: install kubeseal (the client) — https://github.com/bitnami-labs/sealed-secrets/releases
# Fetch the controller's PUBLIC key (safe to cache / share):
kubeseal --controller-namespace sealed-secrets --fetch-cert > pub-cert.pem

# Author a normal Secret WITHOUT applying it, then seal it. The output MUST be
# named sealedsecret-*.yaml and land in the project's infra/ directory:
kubectl create secret generic app-api-keys -n proj-scoutid \
  --from-literal=stripe=sk_live_xxx --dry-run=client -o yaml \
  | kubeseal --cert pub-cert.pem --format yaml \
  > k8s/projects/proj-scoutid/infra/sealedsecret-app-api-keys.yaml

# Commit it. ArgoCD applies it; the controller decrypts it into the real Secret
# `app-api-keys` in namespace proj-scoutid.
```

> **The filename and location are load-bearing.** The `project-infra`
> ApplicationSet syncs only `k8s/projects/<project>/infra/` and only files
> matching its `include` list — which covers `sealedsecret-*.yaml`. A sealed
> secret committed anywhere else, or named anything else, is **ignored silently**:
> no error in ArgoCD, no event, just a Secret that never appears. Verify with
> `kubectl get sealedsecret -n <namespace>` (expect `SYNCED: True`) rather than
> assuming the commit was enough.

The plaintext never touches Git — only the sealed form, which is bound to *this*
cluster's key and *this* namespace/name (it cannot be moved or decrypted
elsewhere). This is the recommended default for a project's own secrets.

> The infra team custodies the single sealing key in Key Vault (so it survives
> rebuilds), but that is a **one-time** setup — no per-secret infra action. See
> docs/install.md.

### Project-owned imperative secrets (no infra team, not in Git)

For a value you're happy to own and re-create yourself and that you'd rather keep
out of Git entirely, just make a plain `Secret` in your namespace. You have
`admin` on it — no infra request.

Best practices so this stays sane and safe:

- **Never commit the plaintext.** A `Secret` YAML with real `data:`/`stringData:`
  in Git (even a private repo) is a leaked secret — `data:` is only base64, not
  encryption. If the value needs to live in Git so ArgoCD can apply it
  declaratively, use **Sealed Secrets** (above) — commit the sealed form — or a
  **Key Vault secret** if it should be centrally custodied.
- **Create it imperatively, out of band**, and keep the value in a password
  manager, not the repo:
  ```bash
  kubectl create secret generic app-api-keys -n proj-scoutid \
    --from-literal=stripe=sk_live_xxx --from-literal=sendgrid=SG.xxx
  ```
  Or `--from-file=` to avoid the value ever appearing in your shell history.
- **Remember the rebuild trade-off.** Imperative Secrets are *not* in Git, so a
  full cluster rebuild does not recreate them — you re-run the command. That's the
  cost of keeping them out of Git. Anything that must survive a rebuild
  automatically belongs in Key Vault (above).
- **Reference, don't inline.** Mount via `envFrom`/`valueFrom: secretKeyRef` or a
  volume — never bake the value into a ConfigMap, image, or Deployment env literal.
- **Scope RBAC.** Secrets are namespaced; a developer with `view` (not `admin`) on
  the namespace cannot read `Secret` contents. Grant `admin` deliberately.

## Add a database (PostgreSQL)

Projects get a **database on the shared Postgres server**, not their own Postgres
instance — most projects here are small, and a dedicated instance per project
reserves far more than it uses. See [postgres.md](postgres.md) for the design and
for when a project should get its own instance instead.

Two commits are involved, because CNPG resolves `spec.cluster` by name within a
namespace: the `Database` and `DatabaseRole` must live beside the shared cluster
(infra-owned), while the connection Secret goes in the project's namespace.

1. **Infra: create the databases.** Generate a password per environment into Key
   Vault, then copy the template and commit.

   **Set `ENVS` to this project's actual environments** — the template and the
   loops below assume `dev prod`, but §A2 makes that set flexible. Add `staging`
   if the project has one; drop `prod` if it does not. `$PROJECT` comes from §A1
   and must still be set in this shell:

   ```bash
   echo "PROJECT=$PROJECT"          # empty? re-run: export PROJECT=<project name>
   ENVS="dev prod"                  # adjust to match this project's namespaces

   for env in $ENVS; do
     az keyvault secret set --vault-name kv-scouterna-webservices \
       --name "postgres-$PROJECT-$env-password" \
       --value "$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)" >/dev/null
   done

   # Confirm one secret per environment before moving on — a wrong or empty
   # $PROJECT produces a plausible name that fails much later, at sync time.
   az keyvault secret list --vault-name kv-scouterna-webservices \
     --query "[?starts_with(name,'postgres-$PROJECT-')].name" -o tsv

   cd "$(git rev-parse --show-toplevel)/k8s/infra-manifest/postgres/databases"
   sed "s/PROJECT/$PROJECT/g" _template.yaml.example > "$PROJECT.yaml"
   ```
   That file holds, **for dev and for prod**, an `ExternalSecret` (the role
   password, from Key Vault), a `DatabaseRole`, and a `Database` owned by it.
   Each environment gets its own role, so a leaked dev credential cannot reach
   prod data.

   **If `ENVS` is not `dev prod`, edit `$PROJECT.yaml` now** — add or delete
   whole blocks so it matches. Then commit; the `postgres-databases` app applies
   it:

   ```bash
   cd "$(git rev-parse --show-toplevel)"
   git add "k8s/infra-manifest/postgres/databases/$PROJECT.yaml"
   git diff --cached                    # check the names before pushing
   git commit -m "Add $PROJECT databases on the shared server"
   ```

   > **Single-namespace project** (§A2's "one namespace only", where the
   > namespace is just `$PROJECT` with no suffix): the env suffix is part of
   > every name in the template, so it cannot be looped away. Use
   > `ENVS="dev"` for the loop above, then in `$PROJECT.yaml` delete the prod
   > block and strip `-dev` from the names in what remains — and rename the Key
   > Vault secret to match (`postgres-$PROJECT-password`), since the loop created
   > it with the `-dev` suffix.

2. **Project: materialize the credentials.** In the project's own directory:
   ```bash
   cd "$(git rev-parse --show-toplevel)/k8s/projects/$PROJECT/infra"
   git mv database.yaml.example database.yaml
   ```
   It produces a Secret named `$PROJECT-db` **in each namespace** — with `host`,
   `port`, `dbname`, `username`, `password` and a ready-made `uri`, each pointing
   at that environment's own database.

   Commit it, then **push both commits** — ArgoCD syncs from the remote, so an
   unpushed commit changes nothing in the cluster:

   ```bash
   cd "$(git rev-parse --show-toplevel)"
   git add "k8s/projects/$PROJECT/infra/database.yaml"
   git status --short                   # one line: R ...database.yaml.example -> database.yaml
   git commit -m "Materialize $PROJECT database credentials"
   git push
   ```

   > **dev + prod is the default**, matching the namespaces in §A2. For a single
   > environment, delete the prod block from **both** files and drop the `-dev`
   > suffix in what remains; for staging, copy a block in each and change the
   > suffix. Remember the matching Key Vault password either way.

3. **Verify** — the database and role exist, and the project's Secret is synced.
   Uses the same `$ENVS` set from step 1:
   ```bash
   kubectl get database,databaserole -n postgres | grep "$PROJECT"   # one pair per env
   for env in $ENVS; do
     kubectl get externalsecret -n "$PROJECT-$env"                   # READY=True
     kubectl get secret -n "$PROJECT-$env" "$PROJECT-db" \
       -o jsonpath='{.data.dbname}' | base64 -d; echo                # PROJECT-<env>
   done
   ```
   **Empty output usually means an unpushed commit, not a broken database.**
   Nothing exists in the cluster until ArgoCD reads it from the remote, and the
   symptom — no `Database`, no `ExternalSecret` — looks identical to a failed
   sync. Check that first:

   ```bash
   git status -sb | head -1        # "ahead N" = not pushed yet
   kubectl get app -n argocd postgres-databases "$PROJECT"   # Synced / Healthy
   ```

   The shared server's own health and backups are infra's concern, not the
   project's: `kubectl get cluster -n postgres shared`.

> Deleting a project's file does **not** drop its data — `prune` is disabled on
> the `postgres-databases` app and `databaseReclaimPolicy: retain` is set.
> Retiring a database is deliberate; see [postgres.md](postgres.md).

## Namespace & PVC backups (Velero)

**Every project namespace is backed up automatically — no onboarding step is
needed.** Velero runs two schedules (`k8s/infra-manifest/velero/schedules/`):

| Schedule | What | When | Retention |
|---|---|---|---|
| `daily-projects` | every project namespace (all except infra ns), **incl. PVC data** | 02:00 daily | 14 days |
| `weekly-full` | the whole cluster (all namespaces) as a safety net | 03:00 Sundays | 35 days |

So a project asking "please back up my PVC" already has it: their namespace and
its persistent volumes are captured daily. Backups go to the `velero` container
in the durable backup storage account (external to the cluster).

> **PVC data capture requires a `VolumeSnapshotClass`** labeled
> `velero.io/csi-volumesnapshot-class: "true"` — provided by
> `k8s/infra-manifest/cluster-infra/snapshotclass/disk-snapshot.yaml`. Without
> it, backups capture namespace/object state but **not** volume contents. (The
> weekly full backup may report `PartiallyFailed` on a few un-snapshottable
> cluster resources — that's expected; it's a best-effort safety net.)

> **`kubectl get volumesnapshot` returns nothing after a successful backup — do
> not read that as failure.** Velero deletes the temporary `VolumeSnapshot`
> object once the durable Azure snapshot exists, and records the snapshot ID in
> the backup. Verify the right way:
> ```bash
> velero backup describe <backup-name> --details    # CSI Snapshots ... Result: succeeded
> ```
> An empty `volumesnapshot` list is the normal steady state.

### Restore a namespace or PVC

> **Verified end-to-end on this cluster (2026-08-10):** backup with a real Azure
> disk snapshot, PVC and pod deleted, restored in place, file contents
> byte-identical (MD5 matched, including an 8 MB random blob); and restored into
> a second namespace with the same checksums. The two gotchas below both came
> out of that test.

Restores need the Velero CLI (`velero` — install from the Velero releases) with
`KUBECONFIG` pointing at the cluster.

1. **Find the backup** to restore from:
   ```bash
   velero backup get                          # list backups
   velero backup describe <backup-name>       # what it contains
   ```
2. **Restore a whole namespace** (recreates its objects + PVCs from snapshots):
   ```bash
   velero restore create --from-backup <backup-name> \
     --include-namespaces <project>-prod
   ```
3. **Restore into a different namespace** (e.g. to inspect data without
   clobbering the live one):
   ```bash
   velero restore create --from-backup <backup-name> \
     --include-namespaces <project>-prod \
     --namespace-mappings <project>-prod:<project>-restore
   ```
4. **Restore only specific resources** — **`--include-resources` silently breaks
   CSI restores.** A filter that omits the snapshot objects produces a restore
   that reports `Completed` while the PVC sits `Pending` **forever**: its
   `dataSource` points at a `VolumeSnapshot` the filter excluded. The tell is
   `CSI Snapshot Restores: <none included>` in `velero restore describe`.
   Either omit the filter, or include the snapshot kinds explicitly:
   ```bash
   velero restore create --from-backup <backup-name> \
     --include-namespaces <project>-prod \
     --include-resources persistentvolumeclaims,persistentvolumes,volumesnapshots,volumesnapshotcontents
   ```
5. **Watch it**:
   ```bash
   velero restore describe <restore-name>
   velero restore logs <restore-name>
   ```

> Velero does not overwrite existing resources by default — to restore over a
> live namespace you typically delete the target objects first, or restore into
> a mapped namespace and swap. Test the exact flow before relying on it.

## Removing a project

The ApplicationSet runs with **prune disabled** for exactly one reason: removing
a project's directory from Git must not silently delete a live namespace and all
its data. To decommission a project, delete its namespace(s) deliberately
(`kubectl delete ns <project>-dev …`) and *then* remove
`k8s/projects/<project>/` from Git.

## Governance by observation (what the infra group watches)

- Grafana dashboard "Namespace Resource Usage" — CPU/memory/PVC per namespace.
- Soft-threshold alerts (`governance-observation` PrometheusRule) notify the
  infra group if a namespace requests a large share of the cluster or a PVC
  fills up. They never block.
- If a namespace starves others, the infra group applies a reactive
  LimitRange / ResourceQuota (`k8s/infra-manifest/cluster-infra/monitor-limits/`)
  to that specific namespace — a temporary corrective, removed once resolved.
