# Grafana dashboards as code

Dashboards here are provisioned into Grafana via GitOps, so they **survive pod
restarts** (unlike dashboards saved through the Grafana UI, which live only in
Grafana's ephemeral SQLite DB and are lost when the pod is recreated).

## How it works

`kustomization.yaml` turns each JSON file under `dashboards/` into a ConfigMap
labeled `grafana_dashboard: "1"`. The kube-prometheus-stack Grafana **dashboard
sidecar** watches for that label in the `observability` namespace and loads them
automatically — no Grafana restart needed. The `grafana-dashboards` Argo CD
Application (in `argocd/bootstrap/observability.yaml`) syncs this folder.

## Add a dashboard

1. Build it in the Grafana UI.
2. **Export the JSON**: Dashboard settings → *JSON Model* (or *Share → Export →
   Save to file*). Give it a stable `uid`.
3. Save the file as `dashboards/<name>.json`.
4. Reference it in `kustomization.yaml` (add to the existing ConfigMap's `files`
   list, or add a new `configMapGenerator` entry).
5. Commit + merge → Argo CD syncs → the sidecar picks it up within ~1 minute.

## Notes

- Reference datasources by **uid** (`loki`, `tempo`, or the Prometheus default),
  not by name, so dashboards keep working across environments.
- Community dashboards (by grafana.com ID) can alternatively be pulled in via
  `grafana.dashboards` in the kube-prometheus-stack values.
- One ConfigMap can hold multiple dashboards (multiple files); Grafana keeps a
  ~1 MiB limit per ConfigMap in mind, so split very large sets across ConfigMaps.
