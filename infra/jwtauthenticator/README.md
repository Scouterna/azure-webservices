# AKS JWT Authenticator (Dex trust)

This makes the AKS API server trust Dex-issued tokens, so Headlamp SSO and
`kubectl` (via kubelogin) authenticate cluster users with their GitHub identity
through Dex. It is **NOT** GitOps/ArgoCD-managed — it is an AKS control-plane
resource applied with `az` (ARM), so it lives here as versioned config and is
applied manually.

## Apply / update

Requires the `aks-preview` CLI extension and the `JWTAuthenticatorPreview`
feature registered on the subscription (it is a **preview** feature — mind the
production-readiness caveat).

```bash
az extension add --name aks-preview
az feature register --namespace Microsoft.ContainerService --name JWTAuthenticatorPreview
az provider register --namespace Microsoft.ContainerService   # after it shows Registered

az aks jwtauthenticator add    -g <rg> --cluster-name <cluster> --name dex --config-file dex.json
# or, to change it:
az aks jwtauthenticator update -g <rg> --cluster-name <cluster> --name dex --config-file dex.json
```

## What `dex.json` does

- **issuer**: trusts tokens from Dex (`https://dex.<host>`), audience `headlamp`.
- **username**: `aks:jwt:<github-login>` (from the `preferred_username` claim).
- **groups**: each GitHub team becomes `aks:jwt:<org>:<team>` (from the `groups`
  claim; Dex emits it because the github connector has `loadAllGroups: true` and
  Headlamp requests the `groups` scope). The `dyn()` cast is required — the
  `groups` claim is typed `any`, which CEL's `.map()` rejects without it.

RBAC then binds these. Infra team access = a `ClusterRoleBinding` of the
`Webservices Infra` team's group string to `cluster-admin`; project developers
get per-namespace `RoleBinding`s on their individual `aks:jwt:<login>` user.

> The exact group string (team name vs slug, spaces) must be read from a real
> token before binding RBAC — do not assume the format.

## Per-host note

`issuer.url` and the host are environment-specific. The test cluster uses
`https://dex.wsinfra.scouterna.net`; the real cluster will use its own Dex host —
update `dex.json` accordingly when porting.
