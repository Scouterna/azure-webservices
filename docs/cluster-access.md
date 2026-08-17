# Cluster access

Who can be cluster-admin, how that is revoked, and what to do when SSO breaks.

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

## Why the file was deleted but the hole stayed open

§12 has always deleted `.kube-webservices` once SSO is proven. That removed the
*copy*, not the *capability*: `properties.disableLocalAccounts` was unset, so
anyone with Azure write access on the cluster could re-issue the same credential
at any time, silently, and use it as an identity that no log attributes to a
human. §12 said as much — "re-run the §7b command" — which made the deletion a
tidy-up rather than a control.

The params now commit `disableLocalAccounts = true`
([`infra/env/webservices.bicepparam`](../infra/env/webservices.bicepparam)), and
§12 turns it off in Azure as well as deleting the file.

**Committed `true`, not `false`.** The insecure state is the one that needs an
explicit act, so a routine redeploy — the `nodeCount` bump-and-redeploy workflow —
re-asserts the secure state instead of silently undoing it. The cost is that a
fresh build cannot bootstrap out of the box, which §7b handles by opening the
window on purpose and §12 closes.

**The bootstrap window is deliberate and bounded.** §7b runs
`az aks update --enable-local-accounts`, bootstraps, and §12 disables again. Both
ends are Azure control-plane operations, so the window has a start and an end in
the Activity Log. Compare the old behaviour, where the credential could be minted
at any time with nothing to show it had happened.

**Break-glass is the same command, not a standing bypass.** If SSO breaks —
JWTAuthenticator is a preview feature ([install.md](install.md) §8b), Dex is a pod
like any other — re-enable local accounts, fix it, disable again. The important
difference from the old state is not that it is harder; it is that it is
*recorded*.

## Why not Entra ID / Azure RBAC yet

The obvious alternative is `aadProfile` with `managed: true` and
`enableAzureRBAC: true`, granting the infra group *Azure Kubernetes Service RBAC
Cluster Admin* — attributable, revocable, and PIM-eligible, which is a better
standing admin path than either of the two above. It is deliberately **not** in
this change, for two reasons:

- **Enabling managed Entra integration is a one-way door.** It cannot be turned
  off again on an existing cluster. That is a decision to take on purpose, not a
  side effect of closing a finding.
- **Its interaction with the JWTAuthenticator is unverified.** Both configure
  authentication on the API server, and the JWT path is a preview feature that is
  currently the *only* way developers reach the cluster. Turning on a second
  authenticator without testing it risks the developer path for a break-glass
  improvement.

Until that is tested on a throwaway cluster, the compensating control is Azure
RBAC hygiene: **the rights that permit `az aks update` on this cluster are now the
only route to cluster-admin outside SSO.** Keep them to as few people as possible
and prefer time-bound (PIM) assignments to standing ones.

## Known limits

- **Disabling is not revocation.** It stops the credential being *issued*. A copy
  taken during the bootstrap window still validates; only rotating the cluster CA
  (`az aks rotate-certs`, disruptive) kills it. A leaked `.kube-webservices` is a
  reason to rotate.
- **In-cluster actions are still unattributed.** No API-server audit log is
  shipped anywhere, so "who did this" is unanswerable regardless of which path
  they used. Closing that is a separate change
  ([maintenance.md](maintenance.md) lists it as not yet implemented).
- **Nothing detects the window being reopened.** Re-enabling local accounts is
  logged in Azure but not alerted on, and the next Bicep redeploy silently
  reverts it — which is the right direction, but means a reopened window can pass
  unnoticed until then. An Activity Log alert would close it.
- **`az aks update` and the deployment can disagree.** Azure holds the live state;
  the committed params hold the intended one. They reconverge on the next
  redeploy, so treat `az aks show --query disableLocalAccounts` as the truth in
  the moment and the params as the truth over time.
