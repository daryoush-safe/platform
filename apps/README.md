# Application services (namespace: `apps`)

UserService, SubscriptionService, DBService, ChatService — each a release of the parameterized
`charts/microservice` chart. Each service owns a directory `apps/<svc>/` holding its
`values.yaml` and its `sealed-secret.yaml` (+ gitignored `secret.unsealed.yaml`). Images are the
GHCR CI builds (`ghcr.io/daryoush-safe/<svc>:sha-...`), pinned by tag; bridge them into
k3s containerd with `docker pull … | sudo k3s ctr images import -` (ghcr is flaky on this
network — see the k3s image-pull notes).

Prereqs: the `data` layer is up (Postgres + Kafka), and the `apps` namespace exists.

## 1. Secrets (Sealed Secrets — committed, GitOps-safe)
Same pattern as `data/postgres`: each service dir holds a plaintext `secret.unsealed.yaml`
(**gitignored**) and its encrypted `sealed-secret.yaml` (**committed**). Each service's Secret carries the
fields its `src/config.py` requires with no default: `DATABASE_URL` + `JWT_SECRET` (all),
plus `STRIPE_SECRET_KEY` + `STRIPE_WEBHOOK_SECRET` (subscription). Non-secret config lives
in each `<svc>.yaml` `env:` block (rendered to a ConfigMap). `DATABASE_URL` is
`postgresql+asyncpg://<role>:<pw>@pg-rw.data.svc.cluster.local:5432/fastapi_ms`; the
password must match the corresponding `pg-*-role` secret, and `JWT_SECRET` must be identical
across all three so tokens validate cross-service.
```bash
KS="kubeseal --controller-name sealed-secrets --controller-namespace kube-system --format yaml"
for svc in userservice subscriptionservice dbservice chatservice; do
  $KS < apps/$svc/secret.unsealed.yaml > apps/$svc/sealed-secret.yaml
done
# No manual kubectl apply — the ApplicationSet syncs each apps/<svc>/sealed-secret.yaml
# (see §2); the controller unseals it → <svc>-secrets.
```

## 2. Deploy the services (GitOps, via Argo CD)
Each service lives in `apps/<svc>/` (`values.yaml` + `sealed-secret.yaml`). An `ApplicationSet`
(`argocd/microservices-appset.yaml`) globs `apps/*/values.yaml` and creates one Argo CD
`Application` per service directory automatically. Each generated Application is multi-source:
the `charts/microservice` chart fed `apps/<svc>/values.yaml`, plus the co-located
`apps/<svc>/sealed-secret.yaml`. Add a new `apps/<svc>/` dir, commit, push, and it deploys —
secret included — with no manual step. See `argocd/README.md`.

The chart runs `alembic upgrade head` in an initContainer, then `uvicorn` in the main
container (both `envFrom` the Secret + ConfigMap).

Manual `helm install` (bootstrap-only / break-glass, bypasses git):
```bash
helm install userservice         charts/microservice -n apps -f apps/userservice/values.yaml
helm install subscriptionservice charts/microservice -n apps -f apps/subscriptionservice/values.yaml
helm install dbservice           charts/microservice -n apps -f apps/dbservice/values.yaml
helm install chatservice         charts/microservice -n apps -f apps/chatservice/values.yaml
```

## Verify
```bash
kubectl get pods -n apps                                  # all 1/1 Ready (readiness = live DB[/Kafka] check)
kubectl exec -n apps deploy/userservice -c app -- \
  python -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8000/readyz').read().decode())"
```
