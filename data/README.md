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
Operator lives in its own `strimzi-system` namespace (mirrors the `cnpg-system` pattern) and
watches `data` via `watchNamespaces`. Strimzi 1.0.x is KRaft-only (no Zookeeper) and ships a
single unified `quay.io/strimzi/operator` image (operator + topic/user-operator + kafka-init).
The Kafka CRDs are `kafka.strimzi.io/v1` (promoted from `v1beta2` as of Strimzi 1.0) and only
support Kafka 4.x — check `STRIMZI_KAFKA_IMAGES` on the operator deployment for the exact
supported versions before bumping `kafka.yaml`'s `spec.kafka.version`.
```bash
helm repo add strimzi https://strimzi.io/charts/
helm repo update
helm upgrade --install strimzi-operator strimzi/strimzi-kafka-operator -n strimzi-system \
  --create-namespace --set watchNamespaces='{data}'
kubectl rollout status deploy/strimzi-cluster-operator -n strimzi-system

kubectl apply -f platform/data/kafka/kafka.yaml
kubectl wait --for=condition=Ready kafka/kafka -n data --timeout=300s
```

## 5. Debezium (Kafka Connect + connectors)
The Connect image (Connect runtime + Debezium Postgres plugin) is built locally and imported
into k3s containerd — **no registry, no Strimzi Kaniko build**. Debezium 3.5.2.Final is the
match for Kafka 4.1.x (built against Connect 4.1.1, bundles kafka-clients-4.1.2); the old
3.0.7 pin was for Kafka 3.x and breaks on 4.x. The build is reproducible via `build.sh`:
```bash
./platform/data/debezium/build.sh     # downloads plugin, docker build, sudo ctr import
kubectl apply -f platform/data/debezium/kafka-connect.yaml
kubectl wait --for=condition=Ready kafkaconnect/connect -n data --timeout=600s
# sanity: the connector class is registered
kubectl exec -n data deploy/connect-connect -- \
  curl -s localhost:8083/connector-plugins | grep -o PostgresConnector
```

The KafkaConnectors read the **outbox tables** (`auth.users_outbox`, `auth.subscriptions_outbox`),
which Alembic creates on first service boot. They CANNOT be applied until the services are
deployed + migrated (Step 4) — apply them then:
```bash
kubectl apply -f platform/data/debezium/connectors.yaml
kubectl get kafkaconnector -n data        # READY should become True
```
NOTE for Step 4: `publication.autocreate.mode: filtered` makes Debezium run `CREATE PUBLICATION
... FOR TABLE`, which requires `debezium_role` to **own** the outbox tables (or be superuser).
The tables will be owned by the service roles, so either pre-create the publications as a
superuser, grant ownership, or switch the connector to a pre-created publication. Resolve when
the services migrate.

## Verify
```bash
kubectl get pods,cluster,kafka,kafkaconnect,kafkaconnector -n data
```
