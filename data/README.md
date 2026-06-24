# Data layer (namespace: `data`)

CloudNativePG (Postgres) + Strimzi (Kafka, KRaft) + Debezium (Kafka Connect). Run from
the repo root (`t2s/`). Order matters: Postgres → Kafka → Debezium.

## 1. CloudNativePG operator
```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace
kubectl rollout status deploy/cnpg-cloudnative-pg -n cnpg-system
```

## 2. Postgres role passwords (out-of-band Secrets; SealedSecrets later)
Replace the CHANGEME values — these same passwords go into the service Secrets in Step 4
(the `DATABASE_URL`s use them).
```bash
kubectl create secret generic pg-user-service-role -n data \
  --from-literal=username=user_service_role --from-literal=password='CHANGEME1'
kubectl create secret generic pg-subscription-service-role -n data \
  --from-literal=username=subscription_service_role --from-literal=password='CHANGEME2'
kubectl create secret generic pg-db-service-role -n data \
  --from-literal=username=db_service_role --from-literal=password='CHANGEME3'
kubectl create secret generic pg-debezium-role -n data \
  --from-literal=username=debezium_role --from-literal=password='CHANGEME4'
```

## 3. Postgres cluster
```bash
kubectl apply -f platform/data/postgres/cluster.yaml
kubectl wait --for=condition=Ready cluster/pg -n data --timeout=300s
```

## 4. Strimzi operator + Kafka
```bash
helm repo add strimzi https://strimzi.io/charts/
helm repo update
helm upgrade --install strimzi strimzi/strimzi-kafka-operator -n data --set watchNamespaces='{data}'
kubectl rollout status deploy/strimzi-cluster-operator -n data

kubectl apply -f platform/data/kafka/kafka.yaml
kubectl wait --for=condition=Ready kafka/kafka -n data --timeout=300s
```

## 5. Debezium (Kafka Connect + connectors)
PREREQUISITE: set `REGISTRY` in `debezium/kafka-connect.yaml` to a registry the cluster can
pull from (the deferred image decision). Then:
```bash
kubectl apply -f platform/data/debezium/kafka-connect.yaml
kubectl wait --for=condition=Ready kafkaconnect/connect -n data --timeout=600s

# Connectors read the outbox tables, which Alembic creates on first service boot.
# Apply these AFTER the services are deployed + migrated (Step 4):
kubectl apply -f platform/data/debezium/connectors.yaml
kubectl get kafkaconnector -n data        # READY should become True
```

## Verify
```bash
kubectl get pods,cluster,kafka,kafkaconnect,kafkaconnector -n data
```
