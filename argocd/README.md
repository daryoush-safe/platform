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

## Repo credentials

Argo CD discovers repo credentials by looking for any `Secret` in `argocd` labeled
`argocd.argoproj.io/secret-type: repository`. The `platform` repo is private, so one must
exist before any `Application`/`ApplicationSet` here can sync:
```bash
kubectl create secret generic platform-repo-creds -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/daryoush-safe/platform.git \
  --from-literal=username=<github-username> \
  --from-literal=password=<PAT-with-repo-read-scope>
kubectl label secret platform-repo-creds -n argocd argocd.argoproj.io/secret-type=repository
```

## Applications

`microservices-appset.yaml` is an `ApplicationSet` — it globs `apps/values/*.yaml` in this
repo and creates one Argo CD `Application` per file, named after the file
(`dbservice.yaml` -> `dbservice`). Add a new service by adding a new values file there and
pushing; no manual `kubectl apply` needed per service.

```bash
kubectl apply -f platform/argocd/microservices-appset.yaml
kubectl get applicationset,application -n argocd
```

Each generated `Application` has `syncPolicy.automated` with `prune: true` and
`selfHeal: true`: pushing a change to a values file deploys it, and any manual
`kubectl edit`/drift on the live resources gets reverted back to match git.
