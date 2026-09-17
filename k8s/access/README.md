# Developer cluster access

`oidc-kubeconfig` is the **shared** kubeconfig every developer uses for `kubectl`
and `helm`. It is safe to commit and to hand out: it contains only the API server
address, the cluster's public CA, and an `exec` block that runs
`kubectl oidc-login` against Dex. There is no token or secret in it — identity is
established at login time, and what you may do is decided by RBAC.

Usage (see docs/onboarding.md section B for the full developer flow):

```bash
brew install kubelogin                                # once; see below
export KUBECONFIG=$PWD/k8s/access/oidc-kubeconfig
kubectl get pods -n <your-namespace>                  # prints a login URL the first time
```

Regenerate it when the cluster is rebuilt — the API server address and CA change.
The command is in docs/install.md §8c.

## Installing the plugin

The `exec` block calls `kubectl oidc-login` — that is [int128/kubelogin][kubelogin],
**not** the Azure tool of the same name. kubectl finds it by the binary name
`kubectl-oidc_login`, and all three of these install it under that name:

- `brew install kubelogin` — Homebrew's plain `kubelogin` **is** int128's, despite
  the name clash. The wrong one is the tap, `brew install Azure/kubelogin/kubelogin`.
- `kubectl krew install oidc-login` — only if you already have [krew][krew].
  Plain kubectl has no `krew` command, so install krew first or use another option.
- A [release binary][releases], put on your `PATH` as `kubectl-oidc_login`.

## When there is no browser on the machine running kubectl

The default flow needs a browser that can reach `http://localhost:8000` **on the
machine running `kubectl`** — `oidc-login` starts a local listener there, and the
login redirect has to come back to it. `--skip-open-browser` only stops the
auto-launch and prints the URL instead; a browser is still required. WSL is fine,
because Windows forwards localhost into the VM. A plain SSH session on a remote
host is not — the browser is then on the wrong machine.

kubelogin has a grant type that needs no local listener: Dex shows a code and you
paste it into the terminal. It takes two extra args in the `exec` block:

```yaml
- --grant-type=authcode-keyboard
- --oidc-redirect-url=urn:ietf:wg:oauth:2.0:oob
```

**This does not work as the cluster stands.** That redirect URL is not registered
on the `kubectl` client in `k8s/infra-manifest/dex/values.yaml`, so Dex rejects
the login. Adding it changes shared auth config — ask the infra team rather than
working around it locally.

[kubelogin]: https://github.com/int128/kubelogin
[releases]: https://github.com/int128/kubelogin/releases
[krew]: https://krew.sigs.k8s.io/docs/user-guide/setup/install/
