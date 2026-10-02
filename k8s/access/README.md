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

Use an SSH tunnel. Log in to the remote host from the machine that has the
browser, forwarding port 8000:

```bash
ssh -L 8000:127.0.0.1:8000 <remote-host>
kubectl get pods -n <your-namespace>      # on the remote host; open the printed URL locally
```

The login ends with a redirect to `http://localhost:8000`. `oidc-login` listens
for it on the machine running `kubectl`, and the tunnel carries it there. The
token is cached on the remote host (`~/.kube/cache/oidc-login`), so the tunnel
is only needed when you have to log in again: after a week without use, and at
least every 30 days. If port 8000 is taken on the remote host, `oidc-login`
falls back to 18000; forward that instead.

WSL needs no tunnel: Windows forwards localhost into the VM.

kubelogin's `authcode-keyboard` grant, where you paste a code instead, does not
work here. Dex rejects it because the `urn:ietf:wg:oauth:2.0:oob` redirect is
not registered, and it is left out on purpose: it would let a phishing link get
a user to hand over a working login code.

[kubelogin]: https://github.com/int128/kubelogin
[releases]: https://github.com/int128/kubelogin/releases
[krew]: https://krew.sigs.k8s.io/docs/user-guide/setup/install/
