# Vendored Grafana dashboards

Dashboard JSON for the infra components. Committed here rather than fetched by
`gnetId` at runtime so that what is reviewed is what runs, and Grafana's startup
does not depend on grafana.com being reachable.

`dashboards-cm/` holds the generated ConfigMaps — that is what ArgoCD syncs (app
`k8s/argocd/infra-apps/dashboards.yaml`). **Edit the JSON here, then regenerate.**

## Sources

| File | Source | Notes |
|---|---|---|
| `traefik.json` | grafana.com **17346** | Needs `metrics.prometheus.addRoutersLabels: true` (set in traefik values) |
| `cloudnative-pg.json` | grafana.com **20417** | Per-database panels stay empty until a project creates a CNPG cluster |
| `cert-manager.json` | grafana.com **11001** | Certificate expiry countdown |
| `velero.json` | grafana.com **11055** | Backup success/failure/duration |
| `external-secrets.json` | [external-secrets repo][eso] | |
| `minio.json` | [minio repo][minio] | The telemetry store's dashboard (it runs MinIO). Scraped via `telemetry-store/servicemonitor.yaml`, not the chart |
| `thanos-query.json` / `-store` / `-compact` | [thanos repo][thanos] | |
| `loki.json` | [loki repo][loki] `loki-chunks` | **Adapted**, see below |
| `namespace-usage.json` | hand-written | Ours, not vendored — same flow as the rest |

[eso]: https://github.com/external-secrets/external-secrets/blob/main/docs/snippets/dashboard.json
[minio]: https://github.com/minio/minio/blob/master/docs/metrics/prometheus/grafana/minio-dashboard.json
[thanos]: https://github.com/thanos-io/thanos/tree/main/examples/dashboards
[loki]: https://github.com/grafana/loki/tree/main/production/loki-mixin-compiled/dashboards

## Loki: single-binary vs microservices

Most Loki mixin dashboards — including the obvious `loki-operational` — assume
**microservices mode** and query per-component jobs (`$namespace/distributor`,
`/query-frontend`, `/ingester`). We run **single-binary mode**, where the only
job is `<namespace>/loki`, so those panels can never return data. Several also
need mixin *recording rules* (`cluster_job:...:sum_rate`) that we do not install.

`loki-chunks` was chosen because it needs neither. Its component-job patterns
(`$namespace/(.*ingester.*)`) are rewritten to `$namespace/loki`. If you swap in
another Loki dashboard, check both before trusting it:

```bash
grep -c 'distributor\|query-frontend\|ingester\|querier' new.json   # component jobs
grep -c ':sum_rate\|cluster_job' new.json                            # recording rules
```

## Regenerating the ConfigMaps

After adding or editing any JSON in this directory:

```bash
cd k8s/infra-manifest/monitoring
python3 - <<'PY'
import json, glob, os, yaml
os.chdir('dashboards'); out='../dashboards-cm'
class L(str): pass
yaml.add_representer(L, lambda d, s: d.represent_scalar('tag:yaml.org,2002:str', s, style='|'))
for p in sorted(glob.glob('*.json')):
    name = p[:-5]
    cm = {'apiVersion':'v1','kind':'ConfigMap',
          'metadata':{'name':f'dashboard-{name}','namespace':'monitoring',
                      'labels':{'grafana_dashboard':'1'}},
          'data':{p: L(open(p).read())}}
    open(os.path.join(out, name+'.yaml'),'w').write(
        yaml.dump(cm, default_flow_style=False, width=10**6, sort_keys=False, allow_unicode=True))
    print(name)
PY
```

Commit **both** the JSON and the regenerated `dashboards-cm/*.yaml`.

> **Changing a dashboard's `uid` needs a Grafana restart.** Provisioning
> reconciles by uid, not filename, so replacing a file's contents with a
> dashboard that has a *different* uid leaves the old one registered and never
> inserts the new one — and the sidecar still logs a successful reload, so the
> 200 OK proves nothing. Editing a dashboard in place is picked up live.
> ```bash
> kubectl -n monitoring rollout restart deployment/kps-grafana
> ```

## Adding a new dashboard

1. Download the JSON (`https://grafana.com/api/dashboards/<id>/revisions/latest/download`)
   or take it from the project's own repo — upstream repos are usually more
   current than grafana.com, and the IDs are easy to misremember.
2. **Strip `__inputs` / `__requires`.** They are import-wizard metadata; the
   sidecar does not run the wizard, so any `${DS_*}` they define stays literal and
   the dashboard renders empty.
3. **Set `id` to `null` and drop `iteration`.** A downloaded dashboard carries
   the numeric `id` it had on grafana.com (and sometimes an `iteration`
   timestamp). Provisioning reconciles by **`uid`**, so `id` means nothing here —
   it is per-instance state that only adds diff noise and invites confusion with
   the grafana.com dashboard number. Keep `uid` and `title`; those are the
   identity.
4. **Point datasource template variables at the real datasource names**
   (`Prometheus`, `Loki`, `Thanos` — see `kube-prometheus-stack-values.yaml`) by
   setting each variable's `current`, so it renders without touching the picker.
5. **Check the metrics actually exist** before trusting the dashboard — a panel
   querying a metric nothing exports is silently empty, not an error:
   ```bash
   kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9099:9090 &
   curl -s 'http://localhost:9099/api/v1/label/__name__/values' | grep -o '"<metric_prefix>[^"]*"' | head
   ```
6. Regenerate the ConfigMaps and commit.
