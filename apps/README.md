# Application services (namespace: `apps`)

UserService, SubscriptionService, DBService — each a release of the parameterized
`charts/microservice` chart, configured by its `<svc>.yaml` values file. Images are the
GHCR CI builds (`ghcr.io/daryoush-safe/<svc>:sha-...`), pinned by tag; bridge them into
k3s containerd with `docker pull … | sudo k3s ctr images import -` (ghcr is flaky on this
network — see the k3s image-pull notes).

Prereqs: the `data` layer is up (Postgres + Kafka), and the `apps` namespace exists.

## 1. Secrets (Sealed Secrets — committed, GitOps-safe)
Same pattern as `data/postgres`: plaintext `secret-*.unsealed.yaml` are **gitignored**,
the encrypted `sealed-secret-*.yaml` are **committed**. Each service's Secret carries the
fields its `src/config.py` requires with no default: `DATABASE_URL` + `JWT_SECRET` (all),
plus `STRIPE_SECRET_KEY` + `STRIPE_WEBHOOK_SECRET` (subscription). Non-secret config lives
in each `<svc>.yaml` `env:` block (rendered to a ConfigMap). `DATABASE_URL` is
`postgresql+asyncpg://<role>:<pw>@pg-rw.data.svc.cluster.local:5432/fastapi_ms`; the
password must match the corresponding `pg-*-role` secret, and `JWT_SECRET` must be identical
across all three so tokens validate cross-service.
```bash
KS="kubeseal --controller-name sealed-secrets --controller-namespace kube-system --format yaml"
for svc in userservice subscriptionservice dbservice; do
  $KS < apps/secret-$svc.unsealed.yaml > apps/sealed-secret-$svc.yaml
done
kubectl apply -f apps/sealed-secret-userservice.yaml \
              -f apps/sealed-secret-subscriptionservice.yaml \
              -f apps/sealed-secret-dbservice.yaml      # controller unseals → <svc>-secrets
```

## 2. Deploy the services
The chart runs `alembic upgrade head` in an initContainer, then `uvicorn` in the main
container (both `envFrom` the Secret + ConfigMap).
```bash
helm install userservice         charts/microservice -n apps -f apps/userservice.yaml
helm install subscriptionservice charts/microservice -n apps -f apps/subscriptionservice.yaml
helm install dbservice           charts/microservice -n apps -f apps/dbservice.yaml
```

## Verify
```bash
kubectl get pods -n apps                                  # all 1/1 Ready (readiness = live DB[/Kafka] check)
kubectl exec -n apps deploy/userservice -c app -- \
  python -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8000/readyz').read().decode())"
```
