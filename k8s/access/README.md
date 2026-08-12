# Developer cluster access

`oidc-kubeconfig` is the **shared** kubeconfig every developer uses for `kubectl`
and `helm`. It is safe to commit and to hand out: it contains only the API server
address, the cluster's public CA, and an `exec` block that runs
`kubectl oidc-login` against Dex. There is no token or secret in it — identity is
established at login time, and what you may do is decided by RBAC.

Usage (see docs/onboarding.md section B for the full developer flow):

```bash
kubectl krew install oidc-login                       # once; int128/kubelogin
export KUBECONFIG=$PWD/k8s/access/oidc-kubeconfig
kubectl get pods -n <your-namespace>                  # opens a browser the first time
```

Regenerate it when the cluster is rebuilt — the API server address and CA change.
The command is in docs/install.md §8c.
