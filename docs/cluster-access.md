# Cluster access

Who can be cluster-admin, why the static admin certificate **cannot** be retired
on this cluster, and what constrains it instead.

## Two paths, and only one of them is attributable

Administering this cluster is meant to be **your GitHub identity**: Dex issues a
token, the API server's JWTAuthenticator trusts it, and RBAC binds the infra
team's GitHub group to `cluster-admin` ([install.md](install.md) §8b, §8c). That
path is attributable to a person, and revoking it is removing them from the GitHub
team.

The other path is the **local admin certificate** — `az aks get-credentials
--admin`. It bypasses Dex, ignores RBAC, authenticates as `masterclient` rather
than as anyone, and cannot be revoked short of rotating the cluster CA. It exists
because a fresh cluster has no working SSO: Dex arrives in wave 2, so something
has to install wave 2.

[install.md](install.md) §12 deletes the file once SSO is proven. That removes the
*copy*. It does not remove the *capability*, and on this cluster the capability
cannot be removed at all.

## Why the certificate cannot be disabled

`properties.disableLocalAccounts` is the property that would remove it. AKS
rejects it on a cluster without Entra integration — not at the Bicep type level,
where it is a perfectly valid property, but in ARM preflight:

```
BadRequest: Since kubernetes version 1.25, disableLocalAccounts can only be set
on Azure AD integration enabled cluster. Please integrate your cluster with AAD.
```

Confirmed twice against a test cluster — 2026-07-21, and again 2026-08-18 on API
`2026-03-01` with Kubernetes 1.36. It is a current constraint, not a stale one or
an artefact of an old API version.

**And Entra integration is ruled out for this cluster, deliberately and
permanently:**

- **Developers are volunteers, and GitHub is their identity.** Managed Entra
  integration would require every project developer to exist as a user or guest in
  Scouterna's Entra tenant. Many are not, and will not be. That is the whole
  reason the cluster runs Dex → GitHub with a JWTAuthenticator instead of Entra.
- **It would tie RBAC to the tenant.** Bindings would reference Entra object IDs
  instead of GitHub team names, against the portability the platform is built
  around ([the top-level README](../README.md)).

Two further objections apply but are not the deciding ones: enabling managed Entra
integration cannot be undone on an existing cluster, and its interaction with the
JWTAuthenticator — a preview feature that is currently the *only* developer path —
is untested.

**So this is settled, not pending.** `aadProfile` is the precondition for
`disableLocalAccounts`; Entra is off the table; therefore the local admin
certificate stays available on this cluster unless the identity model itself
changes. It is not a to-do.

## What constrains it instead

The rights that permit `az aks get-credentials --admin` are **the only route to
cluster-admin outside SSO**, which makes Azure role hygiene the real control here
rather than a fallback:

- Grant **`Azure Kubernetes Service Cluster Admin Role`** — and `Contributor` on
  the cluster resource group, which also implies it — to as few people as
  possible.
- Make those assignments **PIM-eligible rather than standing**: time-bound,
  approval-gated, and logged at activation. A standing assignment is a permanent
  cluster-admin held by whoever has it.
- Review the assignment list as deliberately as the cluster's own RBAC:

  ```bash
  az role assignment list -g $CLUSTER_RG --include-inherited \
    --query "[].{who:principalName, role:roleDefinitionName, scope:scope}" -o table
  ```

## Known limits

- **Use of the certificate is attributable in Azure, not in the cluster.**
  Minting it calls
  `Microsoft.ContainerService/managedClusters/listClusterAdminCredential/action`,
  a control-plane operation, so the Activity Log should record who asked for it —
  worth confirming once on this tenant, because it is the only attribution
  available. What it *does* afterwards is unattributed: every request arrives as
  `masterclient`.
- **Deleting the file is not revocation.** A copy taken before §12 keeps working.
  Only rotating the cluster CA (`az aks rotate-certs`, disruptive) invalidates it,
  so a leaked `.kube-webservices` is a reason to rotate rather than merely to
  delete.
- **The audit log records the certificate's actions as `masterclient`.**
  `kube-audit-admin` now ships off-cluster ([decisions.md](decisions.md) entry 9),
  so SSO actions are attributable to a GitHub identity — but certificate requests
  carry no person, whatever the log captures. Azure's record of who *minted* it
  stays the only link to a human.
- **If the identity model ever changes**, this decision is what to revisit — an
  Entra-integrated cluster could disable the certificate, at the cost of the
  volunteer-friendly GitHub identity that motivated the current design.
