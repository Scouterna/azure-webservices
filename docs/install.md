# Installing the Webservices v2 cluster

This is the full runbook: from an empty subscription to a running, GitOps-managed
cluster. It is **one continuous shell session** — work top to bottom in a single
terminal. The variables you set in §0 stay live through every later command, so
they are never repeated; a command near the end still uses a variable set at the
start.

The order follows the **dependencies**, not the topic:

1. **Prerequisites** that need nothing from the cluster (quota, GitHub OAuth app,
   Key Vault, identities, secrets, backup storage) — done first, before you spend
   anything on a cluster.
2. **Provision** the cluster.
3. **Cluster-derived wiring** — the few things that need values only a running
   cluster produces (its OIDC issuer, its node resource group).
4. **Bootstrap ArgoCD**, which brings up every common service from Git.

Prerequisite tooling: `az` logged in and pointed at the right subscription
(`az account set --subscription <id>`); `bicep` CLI **0.44.1+** (older versions
can't type-check the `2026-03-01` AKS API — `az bicep upgrade`); `kubectl`; `git`.
The common services are installed **entirely by ArgoCD** — there is no manual
`helm install`.

---

## 0. Environment variables (set these once)

Set these at the top of your shell session. Defaults are the real Scouterna
production values; override any of them for a test deploy (e.g. a throwaway
`CLUSTER`/`CLUSTER_RG`). Everything below refers to these — they are never
re-declared.

```bash
# --- Cluster ---
CLUSTER=webservices-v2            # AKS cluster name (also the dnsPrefix)
CLUSTER_RG=webservices-v2         # resource group that will hold the cluster
LOCATION=swedencentral            # Azure region for everything here

# --- Durable infrastructure (survives cluster teardown/rebuild) ---
INFRA_RG=webservices-infra        # RG holding the Key Vault, identities, backup storage
KEY_VAULT_NAME=kv-scouterna-webservices       # Key Vault name (globally unique, 3-24 chars)
BACKUP_STORAGE_ACCOUNT=stwsv2backup              # backup storage account (globally unique, 3-24 lowercase alnum)

# --- Identities (in $INFRA_RG; persist across rebuilds) ---
ESO_IDENTITY=id-eso-webservices       # managed identity ESO authenticates as
VELERO_IDENTITY=id-velero-webservices # managed identity Velero authenticates as
FEDCRED_ESO=eso-$CLUSTER              # ESO federated-credential name (one per cluster)
FEDCRED_VELERO=velero-$CLUSTER        # Velero federated-credential name (one per cluster)

# --- DNS / access ---
HOST=wsinfra.scouterna.net        # DNS suffix for the infra apps (Grafana, Headlamp, ...)

# --- Subscription (set EXPLICITLY — see the warning below) ---
SUBSCRIPTION_ID=<the-target-subscription-id>
az account set --subscription "$SUBSCRIPTION_ID"
```

> ⚠️ **Pin the subscription before anything else.** `az` remembers a default
> subscription across sessions, and it may not be the one you think — a login for
> unrelated work silently changes it. Every command below acts on whatever
> subscription is active, including the destructive ones (`az group delete` in a
> teardown). Deploying — or deleting — in the wrong subscription is the single
> most damaging mistake available here, so set it explicitly rather than deriving
> it from the current login, then **verify** you are where you intend to be:
>
> ```bash
> az account show --query "{name:name, id:id}" -o table   # is this the right one?
> az group list --query "[].name" -o tsv | head           # do these look familiar?
> ```
>
> Re-run the `az account set` line whenever you open a new terminal for this
> runbook.

> A few values are read from the *running cluster* later (its OIDC issuer, its
> node resource group) and are set into variables at that point (§7, §8).

---

# Part 1 — Prerequisites (no cluster needed)

Everything in Part 1 can be done before the cluster exists. On a **rebuild**, the
durable pieces ($INFRA_RG, $KEY_VAULT_NAME, the identities, $BACKUP_STORAGE_ACCOUNT, the secrets) usually
already exist and these steps are idempotent no-ops — safe to re-run.

## 1. vCPU quota (do this FIRST — it blocks the deploy)

A fresh subscription in `$LOCATION` typically has **0** quota for the VM family we
use and a low total-regional cap. Check and raise before deploying.

```bash
SCOPE="subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Compute/locations/$LOCATION"
az quota show --resource-name standardDSv6Family --scope "$SCOPE" --query '{name:name.value, limit:properties.limit.value}' -o table
az quota show --resource-name cores             --scope "$SCOPE" --query '{name:name.value, limit:properties.limit.value}' -o table
```

The bare `-o table` prints only the `Name` column — the limit lives in a nested
field it drops; the `--query` above pulls out the number. One `Standard_D4s_v6`
node needs **4 vCPU**; if both limits are already ≥ 4 (with regional headroom) you
can skip ahead. A limit of **0** (common on a fresh subscription) blocks the
deploy — raise it (values are examples; leave headroom for a 2nd node + surge):

```bash
az quota update --resource-name standardDSv6Family --scope "$SCOPE" --limit-object value=16 --resource-type dedicated
az quota update --resource-name cores              --scope "$SCOPE" --limit-object value=32 --resource-type dedicated
```

**Gotchas:**
- The cluster uses **`Standard_D4s_v6`** (Intel, `standardDSv6Family`) — chosen
  over the equally-sized AMD `Standard_D4as_v5` because v6 allows **12 attachable
  data disks instead of 8**, and disk count (not CPU or memory) is what this
  cluster runs out of first. See [postgres.md](postgres.md) and the disk note below.
- The older Intel `standardDSv5Family` is **not grantable** on this subscription
  (`QuotaNotAvailableForResource` from the direct quota API). That restriction is
  specific to the v5 family — **`standardDSv6Family` is grantable**, so v6 gets us
  Intel and more disk slots at the same size and price class.
- `az quota update` needs the `quota` CLI extension (`az extension add --name quota`).
- On some subscriptions (notably **Sponsorship**) `az quota update` is rejected —
  raise it from the portal instead: *Subscription → Usage + quotas → find the
  family → Request increase*.
- Ephemeral OS disk is **not supported** on `D4s_v6` (it has no local temp disk) —
  we use a managed OS disk (already set in `infra/aks.bicep`). The `D4ds_v6`
  variant does have local NVMe if that ever becomes desirable; `emptyDir` does
  **not** need it, and falls back to the OS disk's ephemeral storage.

## 2. GitHub OAuth apps (Grafana login + Dex SSO)

The cluster uses GitHub as its identity provider in **two independent places**, so
you need **two separate GitHub OAuth Apps** (they have different callback URLs and
cannot share one registration):

| OAuth App | Used by | Why separate |
|---|---|---|
| **Grafana** | Grafana's own `auth.github` login | Callback `…/login/github` |
| **Dex** | Dex → Headlamp *and* `kubectl` SSO | Callback `…/callback`; Dex fronts all cluster auth |

Both are restricted to the **Scouterna** org. Do this before writing the Key Vault
secrets (§6) so both client secrets are ready.

### 2a. Grafana OAuth app

Daily Grafana login is **GitHub OAuth**, with GitHub teams → Grafana roles (config
in `kube-prometheus-stack-values.yaml`, `grafana.ini` `auth.github`). The admin
password is **break-glass only**.

1. Create a **GitHub OAuth App** (Scouterna org → Settings → Developer settings →
   OAuth Apps): Homepage `https://grafana.$HOST`, callback
   `https://grafana.$HOST/login/github`.
2. Capture its **Client ID** and **Client Secret** — the ID fills a Grafana
   manifest (§9), the secret goes into Key Vault (§6):
   ```bash
   GRAFANA_GITHUB_CLIENT_ID=<client-id-from-the-grafana-oauth-app>
   GRAFANA_GITHUB_CLIENT_SECRET=<client-secret-from-the-grafana-oauth-app>
   ```
3. Later, set `role_attribute_path` in the Grafana values to the real Scouterna
   team slugs.

### 2b. Dex OAuth app (developer SSO for Headlamp + kubectl)

Dex is the cluster's OIDC provider: developers log in to **Headlamp** and get
**`kubectl` credentials** as their GitHub identity, with GitHub teams mapped to
RBAC. Without this, Headlamp and `kubectl` SSO do not work. See
[onboarding.md](onboarding.md) section B.

1. Create a **second GitHub OAuth App**: Homepage `https://dex.$HOST`, callback
   **`https://dex.$HOST/callback`**.
2. Capture its Client ID and Client Secret, plus invent a random shared secret for
   the Dex↔Headlamp static client:
   ```bash
   DEX_GITHUB_CLIENT_ID=<client-id-from-the-dex-oauth-app>
   DEX_GITHUB_CLIENT_SECRET=<client-secret-from-the-dex-oauth-app>
   DEX_HEADLAMP_CLIENT_SECRET=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
   ```
   `DEX_GITHUB_CLIENT_ID` fills a Dex manifest (§9); the two secrets go into Key
   Vault (§6). The Headlamp secret is **not** issued by GitHub — it is a value you
   invent, shared between Dex's `headlamp` static client and Headlamp itself.

> Deferring GitHub login? Set the variables to placeholder strings now — the
> cluster comes up fine, and only the GitHub logins stay inactive until you set the
> real values, re-write the Key Vault secrets (§6), re-fill the manifests (§9), and
> re-push. Note that deferring the **Dex** app also defers `kubectl` SSO, so you
> will be relying on the admin kubeconfig until it is configured.

## 3. Durable Key Vault

The Key Vault lives in the **durable** resource group ($INFRA_RG) so it survives
cluster teardown/rebuild.

```bash
az group create -n $INFRA_RG -l $LOCATION
az deployment group create -g $INFRA_RG -f infra/keyvault.bicep -p keyVaultName=$KEY_VAULT_NAME
```

The `-g $INFRA_RG` on the deployment is what places the vault in that resource
group — the Bicep names no RG itself. The vault inherits the RG's location
(`keyvault.bicep` uses `resourceGroup().location`), so the RG's `-l $LOCATION` puts
the vault in the right region too.

> **Gotcha:** Key Vault names are globally unique across ALL Azure tenants, and
> `az keyvault check-name` is optimistic (can report a taken name as available). A
> generic name like `kv-webservices` was already taken → deploy failed with
> `VaultAlreadyExists`. Use a distinctive namespaced name. The vault uses **RBAC
> authorization** + **purge protection** (see the Bicep).

## 4. Managed identities + Key Vault role grant

Two managed identities live in $INFRA_RG and persist across rebuilds: one for ESO
(reads Key Vault), one for Velero (writes backups). Create them and grant ESO read
access to the vault:

```bash
KEY_VAULT_ID=$(az keyvault show -n $KEY_VAULT_NAME --query id -o tsv)

# ESO identity — reads secrets from the Key Vault
az identity create -g $INFRA_RG -n $ESO_IDENTITY -l $LOCATION
ESO_PRINCIPAL=$(az identity show -g $INFRA_RG -n $ESO_IDENTITY --query principalId -o tsv)
az role assignment create --assignee-object-id "$ESO_PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" --scope "$KEY_VAULT_ID"

# Velero identity — created now; its role grants (on the backup storage) are in §5
az identity create -g $INFRA_RG -n $VELERO_IDENTITY -l $LOCATION
```

The federated credentials that bind these identities to the *cluster* come later
(§7) — they need the cluster's OIDC issuer, which doesn't exist yet.

## 5. Backup storage account (Velero + CNPG)

Backups go to a durable, external storage account in $INFRA_RG (see
`infra/backup-storage.bicep`). Storage account names are **globally unique, 3–24
chars, lowercase alphanumeric only** (no hyphens). On a rebuild it usually already
exists — the deployment is idempotent.

```bash
az deployment group create -g $INFRA_RG -f infra/backup-storage.bicep -p storageAccountName=$BACKUP_STORAGE_ACCOUNT

VELERO_PRINCIPAL=$(az identity show -g $INFRA_RG -n $VELERO_IDENTITY --query principalId -o tsv)
STORAGE_ID=$(az storage account show -g $INFRA_RG -n $BACKUP_STORAGE_ACCOUNT --query id -o tsv)
az role assignment create --assignee-object-id "$VELERO_PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" --scope "$STORAGE_ID"   # data plane
az role assignment create --assignee-object-id "$VELERO_PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role "Reader" --scope "$STORAGE_ID"                          # mgmt plane (REQUIRED)
```

> **Note:** the Velero identity needs **both** `Storage Blob Data Contributor`
> **and** `Reader`. With only the data-plane role the BackupStorageLocation
> validates as Available but backups stall on a silent 403.

The `velero` and `cnpg-shared` containers are both created by the Bicep
deployment above — the shared Postgres server's container must exist **before**
it starts archiving (unlike Velero, CNPG's `ObjectStore` does not create one;
without it the `Cluster` comes up but `ContinuousArchiving` never goes `True`).

The shared PostgreSQL server additionally needs the **storage-account key** in
Key Vault. Velero uses Workload Identity,
but the CNPG Barman plugin still needs a key (its Managed-Identity path is
finicky with multiple node identities), and ESO reads it from the vault:

```bash
az keyvault secret set --vault-name $KEY_VAULT_NAME --name backup-storage-account-key \
  --value "$(az storage account keys list -g $INFRA_RG -n $BACKUP_STORAGE_ACCOUNT \
              --query '[0].value' -o tsv)" >/dev/null
```

> Without this secret the failure is quiet: the `Cluster` starts and serves
> queries, `postgres-backup-storage` sits `SecretSyncedError`, and
> `ContinuousArchiving` never goes `True` — a working database that is not being
> backed up. **§11 verifies this** once there is a cluster to verify against.

> **REBUILD ONLY — the `cnpg-shared` container must be EMPTY.** Barman refuses to
> archive into a destination that already holds another server's backups, and the
> storage account is durable, so a rebuild inherits the old cluster's blobs. The
> symptom is identical to the missing-key case above: `Ready=True`, queries
> served, `ContinuousArchiving=False`, nothing archived. Check, and clear the old
> server's prefix if anything is there:
> ```bash
> KEY=$(az storage account keys list -g $INFRA_RG -n $BACKUP_STORAGE_ACCOUNT --query '[0].value' -o tsv)
> az storage blob list --account-name $BACKUP_STORAGE_ACCOUNT --account-key "$KEY" \
>   -c cnpg-shared --query 'length(@)'      # expect 0 on a fresh install
> az storage blob delete-batch --account-name $BACKUP_STORAGE_ACCOUNT --account-key "$KEY" \
>   -s cnpg-shared --pattern 'shared/*'     # only if the above is non-zero
> ```
> Use the **account key**, not `--auth-mode login`: listing blobs needs a Storage
> Blob Data role that infra logins do not necessarily hold, and the failure looks
> like an empty container rather than a permission error. Leave the other
> containers alone — `velero` and any `cnpg-<project>` hold live backups.

## 6. Write the bootstrap secrets to Key Vault

**Key Vault is the source of truth.** ESO's `ExternalSecret`s (in
`k8s/infra-manifest/external-secrets/`) materialize these into the cluster, so a
**rebuild recreates them automatically** — you never hand-create in-cluster
secrets.

First let yourself write secrets (under an RBAC vault even the creator needs an
explicit role), then set the four secrets. The GitHub client secret is the real
value from §2.

```bash
# Grant yourself write access (once), then wait for RBAC to propagate
ME=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
  --role "Key Vault Secrets Officer" --scope "$KEY_VAULT_ID"
sleep 20

az keyvault secret list --vault-name $KEY_VAULT_NAME --query "[].name" -o tsv   # what already exists (durable vault)

az keyvault secret set --vault-name $KEY_VAULT_NAME --name minio-root-user             --value admin
az keyvault secret set --vault-name $KEY_VAULT_NAME --name minio-root-password         --value "$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
az keyvault secret set --vault-name $KEY_VAULT_NAME --name grafana-admin-password      --value "$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
az keyvault secret set --vault-name $KEY_VAULT_NAME --name grafana-github-client-secret --value "$GRAFANA_GITHUB_CLIENT_SECRET"

# Dex SSO (§2b) — without these, Headlamp and kubectl SSO do not work
az keyvault secret set --vault-name $KEY_VAULT_NAME --name dex-github-client-secret   --value "$DEX_GITHUB_CLIENT_SECRET"
az keyvault secret set --vault-name $KEY_VAULT_NAME --name dex-headlamp-client-secret --value "$DEX_HEADLAMP_CLIENT_SECRET"
```

**Sealed Secrets sealing key (do this once; it must survive every rebuild).** The
Sealed Secrets controller would otherwise generate its own RSA key on first start
and self-rotate it — a rebuild would then mint a *new* key and make every
committed `SealedSecret` undecryptable. So we generate one long-lived key pair,
store it in the durable Key Vault, and let ESO re-materialize it on each rebuild
*before* the controller starts (which adopts it instead of generating a fresh
one). Auto-rotation is disabled in the controller values (`keyrenewperiod "0"`).
Generate and store the pair **only if it isn't already in the vault** (a rebuild
must reuse the existing one):

```bash
if ! az keyvault secret show --vault-name $KEY_VAULT_NAME --name sealed-secrets-tls-key >/dev/null 2>&1; then
  openssl req -x509 -nodes -newkey rsa:4096 -keyout /tmp/ss-tls.key -out /tmp/ss-tls.crt \
    -subj "/CN=sealed-secret/O=sealed-secret" -days 3650
  az keyvault secret set --vault-name $KEY_VAULT_NAME --name sealed-secrets-tls-crt --file /tmp/ss-tls.crt
  az keyvault secret set --vault-name $KEY_VAULT_NAME --name sealed-secrets-tls-key --file /tmp/ss-tls.key
  shred -u /tmp/ss-tls.key /tmp/ss-tls.crt    # never leave the private key on disk
fi
```

The `ExternalSecret`s then produce the in-cluster secrets consumers expect:
`minio-root`, `loki-minio`, `thanos-objstore` (composed from the MinIO values),
`grafana-admin`, `grafana-github-oauth`, `dex-oauth` (Dex's GitHub + Headlamp
client secrets), `headlamp-oidc` (the same Headlamp secret, in its own namespace),
and the Sealed Secrets `sealed-secrets-key` (a `kubernetes.io/tls` Secret labelled
`active`, which the controller adopts).

> **How the ordering works (no hand-seeding):** sync-waves are arranged so secrets
> exist before the things that use them. The ESO operator is wave 0; the
> `ClusterSecretStore` + `ExternalSecret`s (the `external-secrets-config` app) are
> wave 1, alongside MinIO and ahead of wave-2 monitoring. If a consumer starts a
> moment before its secret is materialized it crash-loops and **self-heals** the
> instant ESO reconciles the value. A rebuild recreates every secret from the Key Vault.

> **Why infra secrets stay on KV/ESO (not Sealed Secrets):** the cluster also runs
> Sealed Secrets (the self-service, commit-safe path for *projects*), so it's fair
> to ask why these infra secrets aren't sealed instead. They shouldn't be, for
> three reasons: **(1) dependency direction** — Sealed Secrets is *built on top of*
> KV/ESO here (its sealing key is itself an `ExternalSecret` from the Key Vault),
> so sealing an infra secret wouldn't remove the KV dependency, only add the
> controller as an extra hop that must be healthy. **(2) Bootstrap ordering** —
> these secrets are consumed in waves 1–2; the sealed-secrets controller is itself
> wave 2, so a sealed infra secret would gain a longer, more fragile dependency
> chain than reading straight from KV. **(3) Value handling** — the random secrets
> (`minio-*`, `grafana-admin-password`) are generated with `openssl rand` directly
> into KV and no human ever sees the plaintext; the GitHub client secrets are
> external values you must custody centrally and rotate. Sealing either would mean
> handling the raw plaintext locally at `kubeseal` time — a downgrade. So: **infra
> secrets → KV/ESO** (early, durable, controller-independent); **project secrets →
> Sealed Secrets or KV/ESO**, the project's choice (see onboarding.md "Secrets").

---

# Part 2 — Provision the cluster

## 7a. Review params + deploy

`infra/env/webservices.bicepparam` holds the cluster shape (name, region, VM size,
node count, SLA tier). It is committed and holds no secrets. The cluster **name**
is overridden on the command line below (so a test deploy needs no edit to the
committed file); if you changed `$LOCATION` or want a different node size/count,
edit the param file.

```bash
az group create -n $CLUSTER_RG -l $LOCATION
az deployment group what-if -g $CLUSTER_RG -f infra/main.bicep -p infra/env/webservices.bicepparam -p clusterName=$CLUSTER   # preview, creates nothing
az deployment group create  -g $CLUSTER_RG -f infra/main.bicep -p infra/env/webservices.bicepparam -p clusterName=$CLUSTER
```

> **`-p clusterName=$CLUSTER` is not optional.** The param file pins
> `clusterName = 'webservices-v2'` (the production name), so without this
> override a test deploy creates a resource group named `$CLUSTER_RG` containing
> a cluster still called `webservices-v2` — and every later step that does
> `az aks show -n $CLUSTER` fails with "not found". A CLI `-p` takes precedence
> over the same parameter in the `.bicepparam` file.

`$CLUSTER_RG` is the cluster's resource group, distinct from the durable
`$INFRA_RG`. AKS also auto-creates a *node* resource group (named
`MC_<cluster-rg>_<cluster>_<location>` by Azure) for the VMs/disks/LB; you don't
create it, and `az group delete -g $CLUSTER_RG` removes both.

A good `what-if` ends with `Resource changes: 1 to create.` and a
`+ Microsoft.ContainerService/managedClusters/<cluster>` block. Deploy takes
~5–10 min.

## 7b. Get credentials + verify

The committed params set `disableLocalAccounts = true`, so the cluster you just
deployed has **no** admin certificate — and no SSO yet either, since Dex arrives in
wave 2. Open that window deliberately, and note when you did:

```bash
az aks update -g $CLUSTER_RG -n $CLUSTER --enable-local-accounts   # ~1 min
```

This is a logged Azure operation, which is the point: the bypass exists only
between here and §12, and both ends of the window are visible in the Activity Log.

```bash
az aks get-credentials -g $CLUSTER_RG -n $CLUSTER --admin --overwrite-existing \
  --file ./.kube-webservices                     # gitignored (.kube-*)
export KUBECONFIG=$PWD/.kube-webservices
kubectl get nodes -o wide                        # Ready, Standard_D4s_v6, AzureLinux
kubectl -n kube-system get pods | grep cilium    # cilium + cilium-operator Running (eBPF dataplane)
```

> **`Operation failed ... local accounts are disabled`** on `get-credentials
> --admin` means the `az aks update` above has not finished, or was skipped.
> Nothing else in the runbook produces that error.

> **`--overwrite-existing` matters on a rebuild.** A rebuilt cluster reuses the
> name but gets a new CA cert and endpoint, so a leftover entry from the previous
> cluster is stale. Without the flag `az` refuses to replace it; with it the entry
> is replaced (it overwrites the matching cluster entry, not the whole file). A
> stale entry fails as TLS or connection errors that read like a broken new
> cluster. To be certain of a clean file, `rm -f ./.kube-webservices` first.

The `--admin` kubeconfig is the infra bootstrap credential — a static cert that
bypasses Dex and RBAC entirely. It is **deleted in §12** once developer SSO is
proven; re-runnable at any time if you need it back.

---

# Part 3 — Cluster-derived wiring

These steps need values only the *running* cluster produces. Fetch them into
variables now.

## 8. Federate the identities to the cluster's OIDC issuer

The cluster's OIDC issuer is **per-cluster** — a rebuild mints a new one, so this
is the one identity step that must be redone each rebuild (the identities and role
grants from Part 1 persist). Both ESO and Velero bind to the same issuer.

```bash
ISSUER=$(az aks show -g $CLUSTER_RG -n $CLUSTER --query oidcIssuerProfile.issuerUrl -o tsv)

az identity federated-credential create -g $INFRA_RG --identity-name $ESO_IDENTITY \
  -n $FEDCRED_ESO --issuer "$ISSUER" \
  --subject "system:serviceaccount:external-secrets:external-secrets" \
  --audiences "api://AzureADTokenExchange"

az identity federated-credential create -g $INFRA_RG --identity-name $VELERO_IDENTITY \
  -n $FEDCRED_VELERO --issuer "$ISSUER" \
  --subject "system:serviceaccount:velero:velero" \
  --audiences "api://AzureADTokenExchange"
```

## 8b. Trust Dex on the API server (developer SSO)

Without this, Headlamp and `kubectl` SSO **do not work**: Dex issues a valid
token, the API server does not trust it, and every request is rejected. It is an
AKS control-plane resource applied with `az` — not GitOps — so it is easy to skip,
and the symptom does not point at it: the GitHub login succeeds and then **bounces
straight back to the login screen**. (A login that succeeds and shows an *empty*
UI is a different fault — that is RBAC, §8c or Headlamp's own role.)

It is placed here, before ArgoCD, because it needs only a running cluster — not
Dex itself. The `az feature register` can take several minutes to leave
`Registering`, so starting it early keeps it off the critical path.

> **Preview feature.** `JWTAuthenticatorPreview` is in preview; weigh that before
> relying on it in production. The cluster is fully usable without it — you just
> administer it with the admin kubeconfig instead of GitHub SSO.

> ⚠️ **`az feature register` is SUBSCRIPTION-wide, not cluster-scoped.** The three
> commands below have three different blast radii, and only one is confined to
> this cluster:
>
> | Command | Scope | Reaches other clusters? |
> |---|---|---|
> | `az extension add` | this **workstation** only | no — just your local `az` |
> | `az feature register` | the whole **subscription** | **yes, potentially** |
> | `az aks jwtauthenticator add` | this **cluster** only | no |
>
> If the subscription also hosts production workloads, registering a preview
> feature there is a decision to make deliberately — not a routine step. In
> practice the risk is low (registering *enables* a capability; it does not alter
> existing clusters, which keep running unchanged unless someone configures a
> JWTAuthenticator on them), but Microsoft's preview terms apply subscription-wide
> and preview features have historically changed defaults for newly-created
> resources. Check what is already registered before adding to it, and note that
> unregistering is possible but re-registering takes minutes:
>
> ```bash
> az feature list --namespace Microsoft.ContainerService \
>   --query "[?properties.state=='Registered'].name" -o tsv     # what is already on
> # az feature unregister --namespace Microsoft.ContainerService --name JWTAuthenticatorPreview
> ```
>
> A side effect of the extension: every later `az aks` command prints
> `WARNING: The behavior of this command has been altered by the following
> extension: aks-preview`. That is expected, not a problem.

```bash
az extension add --name aks-preview                                    # once per workstation
# "No stable version ... Preview versions allowed" and "already installed" are
# both normal: aks-preview only ever ships preview builds.

az feature register --namespace Microsoft.ContainerService --name JWTAuthenticatorPreview
az feature show --namespace Microsoft.ContainerService --name JWTAuthenticatorPreview \
  --query properties.state -o tsv                                      # wait for "Registered"
az provider register --namespace Microsoft.ContainerService            # after it shows Registered
```

`infra/jwtauthenticator/dex.json` carries the claim mappings. **Its `issuer.url`
is the one place `$HOST` is hardcoded** rather than substituted — everything else
in this runbook derives from the variable, so this file is the one that silently
points at the wrong cluster after a copy. Assert it, and rewrite it if it does not
match:

```bash
# Fails loudly if the issuer does not match this cluster's $HOST.
grep -q "\"url\": \"https://dex.$HOST\"" infra/jwtauthenticator/dex.json \
  && echo "issuer OK: https://dex.$HOST" \
  || echo "MISMATCH — currently: $(grep -o 'https://dex\.[^"]*' infra/jwtauthenticator/dex.json)"

# If it mismatched, point it at this cluster (then commit the change):
sed -i "s#\"url\": \"https://dex\.[^\"]*\"#\"url\": \"https://dex.$HOST\"#" \
  infra/jwtauthenticator/dex.json

az aks jwtauthenticator add -g $CLUSTER_RG --cluster-name $CLUSTER \
  --name dex --config-file infra/jwtauthenticator/dex.json
# use `update` instead of `add` if one already exists
```

> A wrong issuer is **not** rejected at apply time — the resource is created
> happily and every login then fails token validation, which looks like a broken
> Dex rather than a stale URL.

This maps a Dex token to a cluster identity: the user becomes
`aks:jwt:<github-login>`, and each GitHub team becomes
`aks:jwt:<org>:<Team Display Name>` — the **display name verbatim, spaces
included**, not the slug.

**Assert it landed before moving on.** This is the only step in Part 3 that
leaves no cluster-visible artifact — no pod, no CR, nothing `kubectl` can show —
so a skipped or failed §8b stays invisible until someone tries to log in at §11,
about fifteen steps later:

```bash
az aks jwtauthenticator list -g $CLUSTER_RG --cluster-name $CLUSTER \
  --query "[].name" -o tsv        # expect: dex
```

Empty output means it was never applied. Re-run the `add` above.

## 8c. Grant the infra team cluster-admin

RBAC still has to say what those identities may do. Bind the infra team's group
string to `cluster-admin` (adjust the team name if yours differs):

```bash
kubectl create clusterrolebinding webservices-infra-admin \
  --clusterrole=cluster-admin \
  --group="aks:jwt:Scouterna:Webservices Infra"
```

> **The group string must match what Dex emits, exactly.** It is the team's
> **display name verbatim** (spaces included), not the slug. A mismatch fails
> **silently** — login succeeds and the user simply sees nothing.
>
> Dex does not exist yet (wave 2, deployed in §10), so this binding is made from
> the known team name now and **confirmed against a real token in §11**. RBAC
> accepts a group that has no members yet, so creating it here is safe.

### The shared developer kubeconfig

Developers reach the cluster with `kubectl` through the same Dex login. They need
a kubeconfig that points at this cluster and shells out to `kubectl oidc-login` —
**onboarding.md tells them to get it from the infra team, so it has to exist.**

It holds **no secrets**: the API address, the cluster's public CA, and an `exec`
block. It is **identical for every developer** — identity is established at login
time, so it can be committed and handed out freely. Generate it once per cluster
(the server address and CA are cluster-specific):

```bash
SERVER=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

cat > k8s/access/oidc-kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: webservices
    cluster:
      server: $SERVER
      certificate-authority-data: $CA
contexts:
  - name: webservices
    context: {cluster: webservices, user: oidc}
current-context: webservices
users:
  - name: oidc
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1beta1
        command: kubectl
        args:
          - oidc-login
          - get-token
          - --oidc-issuer-url=https://dex.$HOST
          - --oidc-client-id=kubectl
          - --oidc-extra-scope=openid
          - --oidc-extra-scope=profile
          - --oidc-extra-scope=email
          - --oidc-extra-scope=groups
          - --oidc-extra-scope=offline_access
        interactiveMode: IfAvailable
EOF
```

Generating it here is fine — the server address and CA come from the running
cluster. **It cannot be tested yet:** it authenticates through Dex, which is
wave 2 and does not exist until §10, and it needs `dex.$HOST` to resolve, which
needs the DNS from §11. Verification is in §11.

> **`--oidc-client-id=kubectl` must be in the JWTAuthenticator's `audiences`.**
> `dex.json` lists both `headlamp` and `kubectl`; if `kubectl` is missing there,
> Headlamp works and `kubectl` fails with `Unauthorized` — the token is valid but
> its audience is not accepted. After changing audiences, run
> `kubectl oidc-login clean` to drop the cached (rejected) token.

> The plugin is [int128/kubelogin][kubelogin-install], **not** Azure's `kubelogin`
> — different tools, same name. Developers install it themselves (onboarding.md
> section B).

[kubelogin-install]: https://github.com/int128/kubelogin

Project developers are *not* granted here — they get per-namespace RoleBindings
through the normal onboarding flow (see [onboarding.md](onboarding.md) section B).

## 9. Fill the manifest placeholders, then commit + push

Gather the remaining values, then fill the `<...>` placeholders in the manifests.
These are Azure identifiers, not secrets — safe to commit.

```bash
# Read the three values only the running cluster / identities can give us.
ESO_CLIENT_ID=$(az identity show -g $INFRA_RG -n $ESO_IDENTITY --query clientId -o tsv)
VELERO_CLIENT_ID=$(az identity show -g $INFRA_RG -n $VELERO_IDENTITY --query clientId -o tsv)
NODE_RESOURCE_GROUP=$(az aks show -g $CLUSTER_RG -n $CLUSTER --query nodeResourceGroup -o tsv)

# Printed in the SAME ORDER as the edits below, one per line, so you can work
# straight down the list.
echo "ESO_CLIENT_ID=$ESO_CLIENT_ID"
echo "GRAFANA_GITHUB_CLIENT_ID=$GRAFANA_GITHUB_CLIENT_ID"
echo "DEX_GITHUB_CLIENT_ID=$DEX_GITHUB_CLIENT_ID"
echo "VELERO_CLIENT_ID=$VELERO_CLIENT_ID"
echo "BACKUP_STORAGE_ACCOUNT=$BACKUP_STORAGE_ACCOUNT"
echo "SUBSCRIPTION_ID=$SUBSCRIPTION_ID"
echo "NODE_RESOURCE_GROUP=$NODE_RESOURCE_GROUP"
echo "KEY_VAULT_NAME=$KEY_VAULT_NAME"
```

Every placeholder is named for exactly one variable, so the rule is always
**`<NAME>` takes `$NAME`**. Work down the list in the order printed above:

| # | File | Placeholder(s) to replace |
|---|---|---|
| 1 | `k8s/argocd/infra-apps/external-secrets.yaml` | `<ESO_CLIENT_ID>` |
| 2 | `k8s/infra-manifest/monitoring/kube-prometheus-stack-values.yaml` | `<GRAFANA_GITHUB_CLIENT_ID>` |
| 3 | `k8s/infra-manifest/dex/values.yaml` | `<DEX_GITHUB_CLIENT_ID>` |
| 4 | `k8s/argocd/infra-apps/velero.yaml` | `<VELERO_CLIENT_ID>`, `<BACKUP_STORAGE_ACCOUNT>`, `<SUBSCRIPTION_ID>` (**twice**), `<NODE_RESOURCE_GROUP>` |
| 5 | `k8s/infra-manifest/external-secrets/clustersecretstore.yaml` | `<KEY_VAULT_NAME>` (inside `vaultUrl`) |

> The two GitHub client ids (rows 2 and 3) are **different values from different
> OAuth apps** — mixing them up breaks that login. That is why neither is called
> just `GITHUB_CLIENT_ID`.

> **Deploying under a different `$CLUSTER` name?** `alloy-values.yaml` hardcodes
> the Loki `cluster` label as `webservices-v2` in **two** places (pod logs and
> Kubernetes events). It is a plain Helm values file with no templating, so it
> cannot pick the name up automatically. Change both or neither — a mismatch
> silently splits logs and events across two `cluster` values, and event panels
> read as empty rather than erroring.

> **Velero's two `resourceGroup` values are different on purpose** (row 4): the
> backup storage location takes `$BACKUP_STORAGE_ACCOUNT`'s resource group
> (`$INFRA_RG`), while the volume snapshot location takes `$NODE_RESOURCE_GROUP`
> — that is where the cluster's disks live. Swapping them breaks backups.

Check nothing was missed before committing:

```bash
scripts/check-placeholders.sh --expect-filled
```

**Then commit and push.** ArgoCD syncs from the Git repo, not your working tree —
an unpushed edit has no effect. Push before applying the root app (§10), and again
whenever you change a filled-in value later:

```bash
# Stage exactly the five files from the table above — never `git add -A`/`-u`,
# which would sweep up anything else you happen to have modified.
git add k8s/argocd/infra-apps/external-secrets.yaml \
        k8s/infra-manifest/monitoring/kube-prometheus-stack-values.yaml \
        k8s/infra-manifest/dex/values.yaml \
        k8s/argocd/infra-apps/velero.yaml \
        k8s/infra-manifest/external-secrets/clustersecretstore.yaml

git diff --cached          # review: only the placeholders you filled should appear
git status --short         # anything still unstaged is intentionally left out

git commit -m "Fill infra client-ids / vault URL"
git push
```

> **Don't miss the `clustersecretstore.yaml` `vaultUrl`.** It's a separate file
> from the client-ids and easy to skip — a left-over `<KEY_VAULT_NAME>` there is
> the most common cause of a stalled bring-up (see Troubleshooting).

---

# Part 4 — Bootstrap ArgoCD

## 10. Install ArgoCD and apply the root app

**Last chance to catch an unfilled placeholder.** From here on ArgoCD syncs
whatever is in Git, and a `<PLACEHOLDER>` reaches Helm as a literal string —
Velero authenticates as a client-id called `<VELERO_CLIENT_ID>` and fails at
**runtime, not at sync**, so the app still reports `Synced`/`Healthy`.

Check **the pushed commit**, not your working tree — that is what ArgoCD reads:

```bash
git fetch origin
scripts/check-placeholders.sh --expect-filled origin/$(git branch --show-current)
```

Anything listed sends you back to §9: fill it, commit, push, re-run.

> This is the reverse of the check CI runs. Upstream `main` is the **template**,
> where the placeholders are supposed to still be there (CI runs
> `--expect-template` and fails if a real value is committed over one). Your
> install branch is the filled-in copy. Both checks use the same script.

```bash
kubectl create namespace argocd
# --server-side is REQUIRED: the applicationsets CRD exceeds the client-side
# last-applied-configuration annotation size limit and a plain apply fails on it.
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.5/manifests/install.yaml

# Wait for ArgoCD to be ready before applying the root app. The
# application-controller (a StatefulSet) is what reconciles the root app, so wait
# for it too — not just the server. Each command blocks until its rollout is done.
kubectl -n argocd rollout status deploy/argocd-server
kubectl -n argocd rollout status deploy/argocd-repo-server
kubectl -n argocd rollout status statefulset/argocd-application-controller

kubectl apply -f k8s/argocd/projects/              # infra + project-infra (+ per-project)
kubectl apply -f k8s/argocd/infra-root-app.yaml    # app-of-apps; recurses infra-apps/ by sync-wave
kubectl apply -f k8s/argocd/projects-root/         # both ApplicationSets (see below)
```

**These three applies are the only hand-applied surface, and they happen once —
here, during installation.** `kubectl` is fine while installing; it is not a
normal-operations tool. Everything after this — a new common service, a new
project, a handed-over workload, even an edit to an AppProject — reaches the
cluster by pushing to Git.

The AppProjects are applied by hand here only because of a bootstrap ordering
problem: `infra-root` cannot sync an Application whose `project:` does not exist
yet. Immediately afterwards the wave `-1` app `argocd-projects` **adopts** the
objects in `k8s/argocd/projects/` and owns them from then on, so later edits are
a commit. Confirm the adoption took:

```bash
kubectl get app -n argocd argocd-projects   # expect: Synced / Healthy
```

Two ApplicationSets make project onboarding work, one per route. Without them a
project can be committed correctly and **nothing happens**, with no error
anywhere. Confirm both exist:

```bash
kubectl get applicationset -n argocd     # expect: project-infra AND project-gitops
```

- **`project-infra`** watches `k8s/projects/*/infra/` and generates the
  infra-owned Application per project (namespaces, developer RBAC, database).
- **`project-gitops`** reads each `k8s/projects/*/gitops.yaml` and generates the
  AppProject + Applications for a project that runs its **own** GitOps repo
  (see [onboarding.md](onboarding.md)). It produces nothing until a project
  declares one, so an empty result from `kubectl get appproject` is normal.

After you apply the root app it takes a minute or two for ArgoCD to discover the
child apps and start syncing them wave by wave — `get applications` showing
nothing (or apps briefly `Missing`/`OutOfSync`) at first is normal.

The root app brings up every common service in dependency order:

| Wave | Services |
|---|---|
| -1 | argocd-projects (adopts the AppProjects applied above, so later edits are a commit) |
| 0 | cluster-infra (StorageClasses + ClusterIssuers), cert-manager, external-secrets (ESO operator), gateway-api-crds |
| 1 | traefik, minio, minio-buckets, cloudnative-pg, external-secrets-config (ClusterSecretStore + ExternalSecrets), barman-cloud-plugin, sealed-secrets-key (durable sealing key ExternalSecret) |
| 2 | monitoring (kube-prometheus-stack + Loki + Alloy), dex, sealed-secrets (controller — after its key), postgres (the shared PostgreSQL server) |
| 3 | thanos, headlamp, postgres-databases (per-project databases on the shared server) |
| 4 | governance (alerts + dashboard), velero |

> **`external-secrets` will go `Degraded` on a first install — this is expected.**
> Its ServiceMonitor cannot be created until the CRD arrives with monitoring in
> wave 2, and ArgoCD's retry budget (5 attempts) is normally spent before then.
> Once monitoring is `Synced`, re-sync ESO — a **refresh is not enough**, because
> it only re-reads Git and does not restart a stalled operation:
> ```bash
> kubectl patch app -n argocd external-secrets --type merge \
>   -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
> ```
> If monitoring itself is stuck at `Unknown`, that is a render failure, not a
> sync failure — one bad source fails the whole multi-source app. Check with
> `kubectl -n argocd get app monitoring -o jsonpath='{.status.conditions}'`.

## 11. Verify + DNS

```bash
kubectl -n argocd get applications                  # sync/health of every service
kubectl -n traefik get svc traefik                  # note EXTERNAL-IP (TWO IPs — v4 and v6)
kubectl -n velero get backupstoragelocation default # -> Available
```

Give it a few minutes and re-run `get applications` — apps should progress to
`Synced`/`Healthy` wave by wave. Then point the infra-app DNS (`*.$HOST`) at the
Traefik LoadBalancer.

If some apps don't come up, see **Troubleshooting** below — the most common cause
is an unfilled placeholder from §9.

### The Sealed Secrets controller adopted the DURABLE key

**Check this on every rebuild — it is a race, and losing it is invisible.** The
controller adopts an existing sealing key if it finds one at startup, and mints
its own if it does not. Sync waves order when apps *start syncing*, not when
their resources are *ready*, so the wave-1 `ExternalSecret` can materialize
seconds after the wave-2 controller has already looked. Observed on a real
install: the controller found no keys 8s after starting, minted its own, and
ESO's key landed 41s later.

A controller running on a self-minted key is **fully healthy in every view** —
and every `SealedSecret` committed against the durable key silently fails to
decrypt, including after the next rebuild.

```bash
kubectl -n sealed-secrets logs deploy/sealed-secrets-controller --tail=50 | grep -i 'private key'
```

Expect `registered private key` with **`secretname=sealed-secrets-key`**. A
generated name like `sealed-secrets-keyXXXXX` means it lost the race. The fix is
a restart, once the durable key exists:

```bash
kubectl -n sealed-secrets rollout restart deploy/sealed-secrets-controller
```

Then confirm the fingerprint matches Key Vault, and that the durable key is the
newest (the controller seals with the most recent key it holds).

### Backups are actually running

Both backup paths report healthy while doing nothing, so check them explicitly.
`BackupStorageLocation: Available` above covers Velero; the shared Postgres needs
its own check, because a `Cluster` that serves queries perfectly can be archiving
nothing at all:

```bash
kubectl get externalsecret -n postgres          # postgres-backup-storage -> READY True
kubectl get cluster -n postgres shared -o jsonpath='{.status.conditions}' | tr ',' '\n' | grep -i archiv
```

`ContinuousArchiving` must be `True`. If it is not, the cause is upstream in the
install: either the `backup-storage-account-key` secret is missing from Key Vault
(§5) or the `cnpg-shared` container does not exist. Both leave the database up
and unbacked-up, and neither raises an alert.

### IMDS is blocked

`deny-imds-egress` (wave 0, in `cluster-infra`) denies egress to the Azure
Instance Metadata Service from every namespace except `kube-system`, closing the
path where any pod mints tokens for the node's kubelet identity. **An unenforced
policy looks identical to an enforced one in `get applications`** — the app is
`Synced` either way, because the object exists. Probe it:

```bash
kubectl get crd ciliumclusterwidenetworkpolicies.cilium.io   # CRD present at all
kubectl get ciliumclusterwidenetworkpolicies deny-imds-egress

kubectl run imds-probe --rm -it --restart=Never -n <project-ns> \
  --image=curlimages/curl:latest -- \
  curl -sS -m 5 -H 'Metadata:true' \
  'http://169.254.169.254/metadata/instance?api-version=2021-02-01'
```

The probe must exit **28** (timeout). Anything else is **not** a pass: a JSON
document means the policy is not being enforced — check the CRD exists and that
`cluster-infra` synced it — and any other failure means the probe never ran.

Then confirm the Azure-authenticating components still work, since they must be
using Workload Identity rather than the node identity:

```bash
kubectl get externalsecrets -A                  # READY True, still refreshing
kubectl -n velero get backupstoragelocation default   # -> Available
```

If an `ExternalSecret` starts failing only *after* this policy applies, it was
silently falling back to the node identity through IMDS — fix the federated
credential (§8), don't widen the policy.

### Dual-stack DNS

The cluster is dual-stack, so the Traefik LoadBalancer has **both** an IPv4 and an
IPv6 public IP. `*.$HOST` needs an **A** record and an **AAAA** record — publishing
only the A record leaves the cluster reachable over IPv4 only, regardless of the
cluster's IPv6 support.

Grab them separately (order within `.status` is not guaranteed, so select by family
rather than by index):

```bash
LB_IPS=$(kubectl -n traefik get svc traefik \
  -o jsonpath='{.status.loadBalancer.ingress[*].ip}' | tr ' ' '\n')
LB_V4=$(echo "$LB_IPS" | grep -v ':' | head -1)
LB_V6=$(echo "$LB_IPS" | grep ':'    | head -1)
echo "A    *.$HOST -> $LB_V4"
echo "AAAA *.$HOST -> $LB_V6"
```

Both records must exist before cert-manager can complete HTTP-01 challenges from
IPv6-only validation paths.

> **IPv6 is fixed at cluster creation.** `ipFamilies` in `infra/aks.bicep` is
> immutable — an existing IPv4-only cluster cannot be converted to dual-stack in
> place. If you inherit a single-stack cluster, it must be rebuilt.

> **`externalTrafficPolicy: Local` is REQUIRED for IPv6 to work.** AKS documents
> that on **Azure Linux** node pools (which this cluster uses) "service objects are
> only supported with `externalTrafficPolicy: Local`". With the default `Cluster`,
> the **IPv6 load-balancer health probe fails and the v6 address silently
> blackholes all inbound traffic** — while IPv4 keeps working, so it looks like a
> broken IPv6 feature rather than a misconfiguration. It is set in
> `k8s/infra-manifest/traefik/values.yaml` under `service.spec`; don't remove it.
> Symptom if it regresses: `curl -6` to the LB times out, `ping6` gets 100% loss,
> and LB `DipAvailability` sits around 50% (one frontend healthy, one not).

> **Verify IPv6 BEFORE publishing the AAAA record.** Let's Encrypt *prefers* IPv6
> when an AAAA exists, so if v6 is unreachable the HTTP-01 challenge fails and
> **no certificate on the cluster will issue** — even though IPv4 is perfectly
> healthy. The failure reads as "certs won't issue", not as an IPv6 problem.
>
> This must run **from a host that has working IPv6** — many workstations and
> Azure Cloud Shell do not. Check the host first; if it has no IPv6, run the
> curl over SSH on one that does:
> ```bash
> # 1. Does THIS host have IPv6 at all?
> curl -6 -sS --max-time 10 https://ipv6.icanhazip.com || echo "no IPv6 here — use a host that has it"
>
> # 2. Then test the LB's v6 address (expects 404/301/200 — anything but a timeout).
> #    $LB_V6 comes from the block above; re-run it if this shell is new.
> curl -sS --max-time 10 -o /dev/null -w '%{http_code}\n' "http://[$LB_V6]/"
>
> # From another host, pass the literal address (variables do not cross ssh):
> ssh <ipv6-capable-host> "curl -sS --max-time 10 -o /dev/null -w '%{http_code}\n' 'http://[$LB_V6]/'"
> ```
> An empty `$LB_V6` produces `curl: (3) URL using bad/illegal format or missing
> URL` — that means the assignment block above did not run in this shell (or
> `KUBECONFIG` was not set), not that IPv6 is broken.

---

## What you can now reach

Once DNS resolves and certificates have issued, the cluster exposes three web
endpoints. Confirm each one before calling the install done:

```bash
for u in grafana headlamp dex; do
  curl -sS --max-time 10 -o /dev/null -w "%{http_code}  https://$u.$HOST\n" "https://$u.$HOST"
done
kubectl get ingress -A          # the authoritative list of what is published
```

| Endpoint | Expected | What it is | Login |
|---|---|---|---|
| `https://grafana.$HOST` | `302` → login | Dashboards, metrics, logs | GitHub OAuth (§2a); break-glass admin in Key Vault |
| `https://headlamp.$HOST` | `200` | Kubernetes UI | GitHub SSO via Dex (§2b) |
| `https://dex.$HOST` | `200` on `/.well-known/openid-configuration` | OIDC provider — not a UI | n/a; it backs Headlamp + `kubectl` |

A `302` from Grafana and `200` from Headlamp mean the ingress, TLS and routing all
work — that is the install-level check. Whether the **login** then succeeds is a
separate, GitHub-side question:

> **Serving correctly but login rejected?** Dex only admits members of the org
> named in `orgs:` in `k8s/infra-manifest/dex/values.yaml` (`Scouterna`). That is
> independent of which org *owns* the OAuth App — an app registered under a
> different org still authenticates you, then Dex rejects you with **"user not in
> required orgs or teams"**. Either join the required org, or point `orgs:` at the
> org your testers actually belong to. Same applies to Grafana's
> `role_attribute_path` team slugs (§2a).

### Headlamp: log in and actually list something

**The `200` above proves nothing about Headlamp working.** That curl hits `/`,
the static frontend, which serves fine no matter what the backend can do. The
probes are slightly stricter — they hit `/config`, a backend route — but that
still answers 200 when the Kubernetes API is unreachable, because Headlamp
returns an empty cluster list rather than an error (and v0.41.0 exposes no
`/healthz`). Headlamp's ServiceAccount is deliberately **not** `cluster-admin`
(see `k8s/infra-manifest/headlamp/service-rbac.yaml`), so if that role is missing
something the pod stays **Running/Ready**, ArgoCD stays **Synced/Healthy**, and
the only symptom is a UI that shows nothing. Nothing alerts.

So verify by using it, once, by hand:

1. Open `https://headlamp.$HOST` and sign in with GitHub via Dex.
2. **List resources** — open a namespace and view its Pods, then open one Pod.
3. Confirm you see the namespaces your team's RBAC grants, and no others.

**Three different faults all read as "SSO is broken" — the symptom tells them
apart, so identify it before digging:**

| Symptom | Cause | Where |
|---|---|---|
| Login **bounces back to the login screen** | API server does not trust Dex's token | **§8b** — assert the JWTAuthenticator exists |
| GitHub rejects you at Dex ("user not in required orgs or teams") | org/team gate | §2b, `orgs:` in dex values |
| Login **succeeds, UI shows nothing** | RBAC | §8c group string, or Headlamp's own role below |

The bounce-back case is the easiest to misread as a permissions problem, because
the login itself works. Check §8b first — it leaves no cluster-visible artifact,
so it is also the easiest step to have skipped:

```bash
az aks jwtauthenticator list -g $CLUSTER_RG --cluster-name $CLUSTER --query "[].name" -o tsv
```

If you are **in** but the UI is blank or errors, then it is RBAC — check the
backend rather than the frontend:

```bash
kubectl logs -n headlamp deploy/headlamp --tail=50 | grep -i -E 'forbidden|error'
kubectl auth can-i --list --as=system:serviceaccount:headlamp:headlamp | head
```

`forbidden` in the logs names the missing verb/resource — add exactly that rule
to the `headlamp-discovery` ClusterRole and commit. Do **not** reach for
`cluster-admin`: that is what this design removed, and it would put a full
cluster-admin token in an internet-facing pod.

### Confirm the group string §8c guessed

That first Headlamp login is the first real token Dex has issued, so it is the
first chance to check the group string bound to `cluster-admin` in §8c. Dex logs
the groups it actually emitted:

```bash
kubectl -n dex logs deploy/dex | grep -i "login successful" | tail -1
```

Prefix each group with `aks:jwt:` to get the RBAC string, and compare against
what was bound:

```bash
kubectl get clusterrolebinding webservices-infra-admin -o jsonpath='{.subjects}'
```

They must match **exactly** — display name, not slug, spaces included. If they
differ, delete the binding and recreate it with the string from the log. The
symptom of a mismatch is not an error: an infra-team member logs in successfully
and sees nothing.

### Verify the developer kubeconfig

The shared kubeconfig written in §8c could not be tested there — Dex did not
exist. Now it does, and DNS resolves:

```bash
kubectl --kubeconfig k8s/access/oidc-kubeconfig get nodes
```

This opens a browser for GitHub login the first time. Success proves the whole
developer path: Dex issues the token, the API server's JWTAuthenticator accepts
its audience, and RBAC grants the access. `Unauthorized` here usually means
`kubectl` is missing from the JWTAuthenticator's `audiences` (§8b) — run
`kubectl oidc-login clean` after fixing it, to drop the cached rejected token.

There is deliberately **no ArgoCD endpoint** — see the next section.

## 12. Retire the admin kubeconfig

`.kube-webservices` (§7b) is the **cluster admin credential** — a static
certificate that bypasses Dex, ignores RBAC, and cannot be revoked short of
rotating the cluster's CA. It exists only to bootstrap a cluster that has no
working SSO yet. Once Dex does work, it is pure liability, so delete the file
**and close the window you opened in §7b**:

```bash
# Prove SSO works BEFORE removing the fallback — this must print nodes.
kubectl --kubeconfig k8s/access/oidc-kubeconfig get nodes

# Only then:
unset KUBECONFIG
rm -f .kube-webservices
az aks update -g $CLUSTER_RG -n $CLUSTER --disable-local-accounts   # ~1 min
```

Deleting the file alone leaves the *capability*: anyone with Azure rights on the
cluster could re-issue the same credential silently. Disabling local accounts is
what removes it, and returns the cluster to the state the committed params
describe. Confirm both:

```bash
az aks show -g $CLUSTER_RG -n $CLUSTER --query disableLocalAccounts -o tsv   # true

# The credential can no longer be issued — this MUST fail.
az aks get-credentials -g $CLUSTER_RG -n $CLUSTER --admin --file /tmp/should-fail \
  && echo "STILL ENABLED — do not proceed" \
  || echo "admin path closed"
```

> **Break-glass**, if SSO breaks and you need in: re-run the `--enable-local-accounts`
> command from §7b, fix the problem, then disable again. Unlike using the cert,
> that is an Azure control-plane operation — attributable to a person in the
> Activity Log, and greppable after the fact:
>
> ```bash
> az monitor activity-log list -g $CLUSTER_RG --offset 30d \
>   --query "[?contains(operationName.value,'managedClusters/write')].{when:eventTimestamp, who:caller}" -o table
> ```
>
> Keep the Azure rights that allow it to as few people as possible, and prefer
> time-bound (PIM) assignments over standing ones — that is now the control that
> matters, since it is the only remaining route to cluster-admin outside SSO.

From here on, use the shared OIDC kubeconfig — your own GitHub identity, subject
to the RBAC from §8c:

```bash
export KUBECONFIG=$PWD/k8s/access/oidc-kubeconfig
kubectl get applications -n argocd
```

> **Do not delete it earlier.** Steps 9–11 and Troubleshooting below run against
> a cluster that may not be healthy yet, and some of that debugging is exactly
> what you would need if Dex itself were broken. Admin is the fallback for that
> case, so it has to outlive the checks that prove SSO works.

`.kube-*` is gitignored, so it was never committed; deleting it removes the copy
on your workstation. Anyone with the file has full cluster control regardless of
GitHub org membership, team, or RBAC — which is why the file goes **and** the
capability behind it goes.

> **Residual risk, stated plainly.** Disabling local accounts stops the credential
> being *issued*; it is not a cryptographic revocation. A copy taken before §12 is
> only reliably killed by rotating the cluster CA
> (`az aks rotate-certs`, disruptive). Treat a leaked `.kube-webservices` as a
> reason to rotate, not merely to disable.

## ArgoCD access — pure GitOps, no exposed GUI

ArgoCD is operated **declaratively**: all config is in Git, changes happen by
commit → auto-sync. There is deliberately **no ArgoCD ingress and no GUI login** —
smaller attack surface, matches the "everything in Git" model.

- **Observe, refresh and sync** with `kubectl` against the `Application` CRs — no
  ArgoCD login, no port-forward, and the action is attributable to you rather
  than to the shared `admin`. See **[argocd.md](argocd.md)** for the full
  lathund; the short version:
  ```bash
  kubectl get app -n argocd                                    # state of everything
  kubectl annotate app -n argocd <app> \
    argocd.argoproj.io/refresh=hard --overwrite                # re-read Git now
  kubectl patch app -n argocd <app> --type merge \
    -p '{"operation":{"initiatedBy":{"username":"'"$USER"'"},"sync":{}}}'   # sync
  ```
- **Debug** a stuck sync via a temporary
  `kubectl -n argocd port-forward svc/argocd-server 8080:443`, logging in with the
  break-glass admin (`kubectl -n argocd get secret argocd-initial-admin-secret
  -o jsonpath='{.data.password}' | base64 -d`). Not for daily use — the kubectl
  path above needs no shared credential.

If a shared dashboard is ever wanted, expose `argocd-server` via Traefik + GitHub
OAuth via ArgoCD's bundled Dex (Scouterna org, teams → RBAC). Not done here by
choice. Note that until it is, `argocd-rbac-cm` is empty and the break-glass
`admin` is unrestricted — one more reason it is not for daily use.

> **A sync overwrites hand edits.** An app left on manual sync (no `automated:`)
> lets a project change the release in the cluster and keeps that drift — but the
> next sync reapplies Git wholesale and discards it. Capture the live state with
> `helm get values <release> -n <namespace>` and fold it into the values file
> *before* syncing. This is the handover step in
> [onboarding.md](onboarding.md) §C.

**Other infra UIs:** Headlamp uses **GitHub SSO via Dex** (§2b) — a developer logs
in as their GitHub identity and sees only the namespaces their RBAC allows; the
same Dex client also issues `kubectl` credentials. There are no ServiceAccount
tokens to hand out (AKS caps them at 24h, which is why this model was adopted).
See [onboarding.md](onboarding.md) section B. Grafana uses its own **GitHub
OAuth** app (§2a).

---

## Troubleshooting (from real bring-ups)

- **Unfilled placeholder = stalled bring-up.** If apps don't reach
  `Synced`/`Healthy`, first check every §9 placeholder was filled, in the right
  file, with the right value — all five files. It's easy to fill the client-ids
  and miss the `vaultUrl` in `clustersecretstore.yaml`:
  ```bash
  scripts/check-placeholders.sh --expect-filled            # your working tree
  scripts/check-placeholders.sh --expect-filled origin/main  # what ArgoCD reads
  ```
- **Store `Ready` but ExternalSecrets `SecretSyncedError`.** A misleading symptom:
  the `ClusterSecretStore` can report `Ready`/`store validated` while still
  pointing at a placeholder vault — Workload-Identity validation doesn't do a live
  fetch — so the `ExternalSecret`s fail with `SecretSyncedError` ("could not get
  secret data from provider") even though the store looks healthy. Check it:
  ```bash
  kubectl get clustersecretstore azure-kv -o jsonpath='{.spec.provider.azurekv.vaultUrl}{"\n"}'
  kubectl get externalsecrets -A     # READY should become True once the URL is real
  ```
  After correcting a value, commit + push, then let ArgoCD re-sync (or
  `kubectl -n external-secrets rollout restart deploy/external-secrets` to force
  ESO to re-evaluate the store immediately).
- **Public repo needs no credential.** For a *private* repo, register an ArgoCD
  repository credential whose `url` scheme **matches** the Application `repoURL`
  (an `https://` repoURL needs an HTTPS/token credential, not an SSH deploy key),
  else `authentication required: Repository not found`.
- **Expected non-"Synced/Healthy" that are fine:** `cloudnative-pg` shows
  `Degraded` when no Postgres `Cluster` CRs exist yet (operator idle);
  `cert-manager`, `thanos`, `external-secrets-config` can sit `OutOfSync/Healthy`
  on benign Helm/CRD field drift. Pods are Running.
- **CRD name clash:** both Velero and CloudNativePG define a `backups` CRD — use
  the fully-qualified `backups.velero.io` / `backups.postgresql.cnpg.io`.
