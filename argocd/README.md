# Argo CD (namespace: `argocd`)

Installed via the upstream static manifest (not Helm — these CRDs/Deployments don't carry
Helm release ownership labels, so `helm upgrade --install` cannot adopt them):

```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.4/manifests/install.yaml
kubectl rollout status deploy/argocd-server -n argocd
```

Get the initial admin password (UI login, username `admin`):
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## Prerequisites (install before syncing)

These are installed out-of-band (like Argo CD itself) because the manifests in this repo
declare their **custom resources**, not the operators. Without them, the corresponding
Applications sync-fail with "unknown kind" until the CRDs exist:

| Operator | Provides CRDs used here | Used by |
| --- | --- | --- |
| [Strimzi](https://strimzi.io) | `Kafka`, `KafkaNodePool`, `KafkaConnect`, `KafkaConnector` | `kafka`, `debezium` |
| [CloudNativePG](https://cloudnative-pg.io) | `Cluster` | `postgres` |
| [sealed-secrets](https://github.com/bitnami-labs/sealed-secrets) | `SealedSecret` | `postgres` roles, every microservice |

The Prometheus Operator (`PrometheusRule`, `AlertmanagerConfig`, `PodMonitor`) is **not** a
prerequisite — it is installed by the `prometheus` Application (kube-prometheus-stack) in an
earlier sync wave than the resources that consume those CRDs.

### Repo credentials

Argo CD discovers repo credentials by looking for any `Secret` in `argocd` labeled
`argocd.argoproj.io/secret-type: repository`. The `platform` repo is private, so one must
exist before the root Application can sync:
```bash
kubectl create secret generic platform-repo-creds -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/daryoush-safe/platform.git \
  --from-literal=username=<github-username> \
  --from-literal=password=<PAT-with-repo-read-scope>
kubectl label secret platform-repo-creds -n argocd argocd.argoproj.io/secret-type=repository
```

## Bootstrap (app-of-apps)

There is a single entrypoint. `root-application.yaml` points at `argocd/bootstrap/` and
syncs every manifest there (`recurse: false`), giving one App/ApplicationSet per platform
tier plus the `platform` `AppProject`:

```bash
kubectl apply -f argocd/root-application.yaml
kubectl get appproject,applicationset,application -n argocd
```

`argocd/bootstrap/`:

| File | Kind(s) | Deploys |
| --- | --- | --- |
| `project.yaml` | AppProject | `platform` project — scopes source repo + allowed destination namespaces |
| `cluster.yaml` | Application | `cluster/` — namespaces + registry pull secrets |
| `data-infra.yaml` | Applications | `kafka`, `postgres`, `debezium` |
| `observability.yaml` | Applications | `prometheus`, `alert-rules`, `alert-configs`, `exporters` |
| `microservices.yaml` | ApplicationSet | one Application per `apps/<svc>/` (see below) |

### Sync ordering

Child Applications carry `argocd.argoproj.io/sync-wave` annotations so the app-of-apps
converges deterministically instead of racing:

- **wave -1** — `platform` AppProject (must exist before any App references it)
- **wave 0** — `cluster-bootstrap` (namespaces first)
- **wave 1** — `kafka`, `postgres`, `prometheus` (infra + the Prometheus Operator CRDs)
- **wave 2** — `debezium` (needs Kafka), `alert-rules`, `alert-configs`, `exporters`,
  and every microservice (need the CRDs / data tier from wave 1)

Every Application also sets `syncPolicy.retry` (5 attempts, exponential backoff) so
transient "CRD not established yet" failures self-resolve, and carries the
`resources-finalizer.argocd.argoproj.io` finalizer so deleting an App (or the root)
cascades to its managed resources instead of orphaning them.

## Microservices ApplicationSet

`microservices.yaml` is an `ApplicationSet` — it globs `apps/*/values.yaml` and creates one
Argo CD `Application` per service directory, named after the dir (`apps/dbservice/` ->
`dbservice`). Each generated Application is multi-source: the `charts/microservice` chart fed
`apps/<svc>/values.yaml`, plus the co-located `apps/<svc>/sealed-secret.yaml`
(`directory.include` keeps the gitignored `*.unsealed.yaml` out). Add a new service by
pushing a new `apps/<svc>/` directory — no manual `kubectl apply` per service, secret
included.

```bash
kubectl get applicationset,application -n argocd
```

Each generated `Application` has `syncPolicy.automated` with `prune: true` and
`selfHeal: true`: pushing a change to a values file deploys it, and any manual
`kubectl edit`/drift on the live resources gets reverted back to match git.
