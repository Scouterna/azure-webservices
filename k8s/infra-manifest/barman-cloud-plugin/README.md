# barman-cloud-plugin — vendored release manifest

`manifest.yaml` is the **published release asset** for
[plugin-barman-cloud](https://github.com/cloudnative-pg/plugin-barman-cloud)
`v0.13.0`, committed here byte-for-byte and applied by the
`barman-cloud-plugin` ArgoCD app.

## Why it is vendored rather than pulled from upstream

The app used to point at the upstream repo's `kubernetes/` path. That is a
kustomize base configured for **testing**, and building it the way ArgoCD does
produces:

```
image:         ghcr.io/cloudnative-pg/plugin-barman-cloud-testing:main
SIDECAR_IMAGE: ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar-testing:main
```

Both are rolling builds on a moving tag, and the **sidecar is what executes
`barman-cloud` inside the Postgres pod** — so the shared database's backup path
would have changed without any commit in this repo. That is the opposite of
"pin everything, upgrade deliberately".

There is no path in the upstream git tree that yields release images: the
in-tree `manifest.yaml` at `v0.13.0` carries the testing images too, and
`config/default` uses `controller:latest`. Only the **release asset** is built
with `:v0.13.0`. ArgoCD cannot fetch a release-asset URL, and a kustomize
`images:` override cannot fix the sidecar, because that one is a base64 value
inside a `secretGenerator` literal rather than an image field.

So the asset is vendored. Compared resource-by-resource against what the old
path produced, the **only substantive differences are those two image
references**. Two further differences are mechanical consequences of them: the
Secret carries a kustomize content-hash suffix
(`plugin-barman-cloud-8tfddg42gf` -> `-m5m67kfh8f`), which moves because the
sidecar image inside it changed, and the Deployment's `secretKeyRef.name`
follows. Both manifests contain the same 17 resources, and every other resource
is byte-identical.

## Verifying the equivalence yourself

The claim above is reproducible — it does not have to be taken on trust:

```bash
tmp=$(mktemp -d)
git clone -q --depth 1 --branch v0.13.0 \
  https://github.com/cloudnative-pg/plugin-barman-cloud.git "$tmp/src"
kubectl kustomize "$tmp/src/kubernetes" > "$tmp/old.yaml"

python3 - "$tmp/old.yaml" k8s/infra-manifest/barman-cloud-plugin/manifest.yaml <<'EOF'
import sys, yaml, json
def load(p):
    out = {}
    for d in yaml.safe_load_all(open(p)):
        if d:
            k, n = d["kind"], d["metadata"]["name"]
            if k == "Secret":           # kustomize hash suffix moves with content
                n = "plugin-barman-cloud-<hash>"
            out[(k, n)] = d
    return out
old, new = load(sys.argv[1]), load(sys.argv[2])
print("same resource set:", set(old) == set(new), f"({len(old)} resources)")
for k in sorted(set(old) & set(new)):
    a = json.dumps(old[k], sort_keys=True)
    b = json.dumps(new[k], sort_keys=True)
    if a != b:
        print("differs:", k)
EOF
rm -rf "$tmp"
```

Expected: the same 17 resources, with only the `Deployment` and the `Secret`
differing — and those only in the image references and the hash suffix that
follows from them.

## Upgrading

1. Download the new release asset and replace the file:
   ```bash
   VER=v0.14.0   # the release you intend to run
   curl -fsSL -o k8s/infra-manifest/barman-cloud-plugin/manifest.yaml \
     "https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/$VER/manifest.yaml"
   ```
2. Confirm it carries release images, not testing ones:
   ```bash
   grep -E '^[[:space:]]+image: ' k8s/infra-manifest/barman-cloud-plugin/manifest.yaml
   python3 -c "import yaml,base64;[print(base64.b64decode(d['data']['SIDECAR_IMAGE']).decode()) \
     for d in yaml.safe_load_all(open('k8s/infra-manifest/barman-cloud-plugin/manifest.yaml')) \
     if d and d.get('kind')=='Secret' and 'SIDECAR_IMAGE' in (d.get('data') or {})]"
   ```
   Neither may contain `-testing` or end in `:main`.
3. Read the upstream changelog for CRD changes. The CRD
   `objectstores.barmancloud.cnpg.io` is in this file, so a bump can change the
   `ObjectStore` schema that `k8s/infra-manifest/postgres/cluster.yaml` uses.
4. Commit both this file and any `ObjectStore` change together.

## Provenance

| | |
|---|---|
| Source | `https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.13.0/manifest.yaml` |
| sha256 | `d2e71e7b06822448f1a421f05781846cfdb9cc621e7ef32eef5e20c5133213b0` |

Verify at any time:

```bash
sha256sum k8s/infra-manifest/barman-cloud-plugin/manifest.yaml
```

## Note for `scripts/check-placeholders.sh`

The vendored CRD contains the literal `<KEY>` in a field description
(`metadata.labels['<KEY>']`), which matches the placeholder pattern. The file is
excluded from that scan by pathspec — it is upstream content, not one of this
repo's install-time templates.
