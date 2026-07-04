# Alert Rules — validation & tuning notes

These `PrometheusRule` files started as the upstream
[Awesome Prometheus Alerts](https://samber.github.io/awesome-prometheus-alerts/)
templates. Those are written for large, multi-node, HA production clusters, so
many rules were either **dead** (the metric doesn't exist in this deployment),
**broken** (bad PromQL / label matching), or **actively noisy** (thresholds that
false-fire on a small, low-traffic homelab).

Every change below was validated against the **live cluster** by querying the
Prometheus API (metric existence + PromQL parse check), not assumed.

## The environment these rules are tuned for

| Aspect | Reality |
|---|---|
| Cluster | single-node **k3s** (`alos`, control-plane only), bare-metal Ubuntu 22.04 |
| Storage | `local-path` provisioner, 5Gi PVCs for Postgres and Kafka |
| Apps | 3 FastAPI/uvicorn services (`user`, `db`, `subscription`) in ns `apps`, `replicaCount: 1`, **no HPA**, mem limit **256Mi**, no CPU limit |
| Kafka | Strimzi KRaft, **1 broker**, `replication.factor=1`, `min.insync.replicas=1` |
| Postgres | CloudNativePG, **1 instance** (no HA), `wal_level=logical` + Debezium logical replication slot (CDC) |
| Metrics | kube-prometheus-stack (node-exporter, kube-state-metrics), kafka-exporter, postgres-exporter, FastAPI `/metrics` |

Because everything is single-replica, "redundancy/HA" alerts don't apply, and
because traffic is low, "too quiet = something's wrong" alerts (which assume
constant production load) produce false positives.

---

## python.yaml — FastAPI runtime

| Rule | Change | Why |
|---|---|---|
| PythonGCObjectsUncollectable | kept (window 5m→10m) | Genuine slow-leak signal (reference cycles). Widened window to cut flapping. |
| PythonFileDescriptorsExhaustion | kept (90%→85%) | The most common way an async app dies slowly (leaked sockets/DB conns). Most valuable rule in the file. |
| PythonGCCollectionsHigh | **removed** | `> 10000 objects/s` is an arbitrary throughput number, not a health signal. Pure noise. |
| PythonGCGeneration2CollectionsHigh | **removed** | Same — gen-2 GC frequency isn't actionable on its own. |
| PythonVirtualMemoryHigh | **removed** | Measured **virtual** memory (meaningless for Python/glibc arenas) with a **4GB** threshold — but the container limit is **256Mi**, so it would be OOMKilled ~16x before this could fire. |
| **FastapiContainerMemoryNearLimit** | **added** | Replacement that actually predicts OOM: container working-set > 90% of its memory limit, scoped to ns `apps`. |

> HTTP request-rate / error-rate / latency (SLO) alerts are intentionally **not**
> here yet — `http_requests_total` and `http_request_duration_seconds_bucket`
> both exist, so those belong in the app-specific rules (next step).

## kafka.yaml

| Rule | Change | Why |
|---|---|---|
| KafkaTopicsReplicas | **removed → replaced** | Broken: compared `min(...) by (topic)` against a `topic,partition`-labelled series, so the label sets never matched and it could never fire. Also claimed "< 3 replicas" on a single-broker RF=1 cluster. |
| **KafkaUnderReplicatedPartitions** | **added** | Uses the exporter's purpose-built `kafka_topic_partition_under_replicated_partition`, correct for any replication factor. On 1 broker this effectively means "partition offline". |
| KafkaConsumerGroupLag | kept (`for` 1m→5m) | Real signal for Debezium + event consumers. Longer `for` avoids flapping during consumer-group rebalances. |
| **KafkaConsumerGroupNoMembers** | **added** | A stalled/crashed consumer stops having members; stronger "consumer is dead" signal than lag alone. |

## postgres.yaml

Group name fixed: `kafka.exporter.rules` → `postgresql.rules` (copy-paste bug).

| Rule | Change | Why |
|---|---|---|
| PostgresqlDown / Restarted / ExporterError | kept | Core health. (Restarted downgraded critical→warning.) |
| PostgresqlTooManyConnections | kept | Relevant: 3 services × (pool 5 + overflow 10) = up to 45 + Debezium + exporter vs default `max_connections=100`. Catches pool leaks. |
| PostgresqlDeadLocks / HighRollbackRate | kept (tuned) | Kept; rollback rate threshold 2%→5% and guarded to only evaluate under real traffic (avoids divide-by-tiny-number spikes at idle). |
| **PostgresqlInactiveReplicationSlot** | kept (renamed) | **One of the most important DB alerts here:** if Debezium's logical slot goes inactive, Postgres retains WAL forever and fills the 5Gi PVC → DB down. |
| PostgresqlTooManyLocksAcquired | kept (critical→warning) | `pg_locks_count` + `pg_settings_*` all exist, so it works. |
| PostgresqlNotEnoughConnections (`< 5`) | **removed** | False positive **right now**: the app DB reports 0 idle connections, so `< 5` fires immediately. Designed for always-busy prod, not a low-traffic app. |
| PostgresqlCommitRateLow (`< 5 commits/5m`) | **removed** | Same problem — flaps whenever the app is idle. |
| PostgresqlTableNotAutoVacuumed | **removed** | Dead: relies on `pg_stat_user_tables_*`, which returns **0 series** (that collector isn't enabled in this postgres-exporter). |
| PostgresqlTableNotAutoAnalyzed | **removed** | Same — dead metric. |
| PostgresqlTooManyDeadTuples | **removed** | Same — dead metric. |

> To bring the vacuum/dead-tuple alerts back, enable the `stat_user_tables`
> collector (or custom queries) on the postgres-exporter first.

## kubernetes.yaml

| Rule | Change | Why |
|---|---|---|
| KubernetesHPA* (×5) | **removed** | No HorizontalPodAutoscalers exist (fixed `replicaCount: 1`); `kube_horizontalpodautoscaler_*` has **0 series**. Re-add with an HPA. |
| KubernetesNodeOutOfPodCapacity | **rewritten** | Upstream expr used a fragile `group_left` join on `kube_pod_info{pod_template_hash=""}` that doesn't evaluate. Replaced with `count(pods per node) / node pod capacity`. |
| KubernetesReplicaSetReplicasMismatch | **removed** | Fires on every rollout and on scaled-down old ReplicaSets; redundant with `KubernetesDeploymentReplicasMismatch`. |
| everything else | kept | Node conditions, OOMKiller, CrashLoop, PVC/volume, StatefulSet, Job/CronJob, API-server & cert alerts all have live series and remain useful. |

## host-and-hardware.yaml

| Rule | Change | Why |
|---|---|---|
| HostSoftwareRaid* (×2) | **removed** | No MD RAID on this node (`node_md_disks` = 0 series). |
| HostEdac* (×2) | **removed** | EDAC collector exposes nothing here (`node_edac_*` = 0 series). |
| HostNetworkBondDegraded | **removed** | No bonded interfaces (`node_bonding_*` = 0 series). |
| HostSystemdServiceCrashed | **removed** | node-exporter's systemd collector is disabled (`node_systemd_unit_state` = 0 series). |
| HostMemoryIsUnderutilized / HostCpuIsUnderutilized | **removed** | `info` cost-optimisation alerts for elastic cloud capacity — meaningless on a fixed homelab node. |
| HostKernelVersionDeviations | **removed** | `info` noise — you patch this box yourself. |
| CPU / mem / disk / inode / disk-latency / network-errors / temp / clock / conntrack / OOM | kept | All have live series and are genuinely useful on a single physical node. |

## prometheus-self-monitoring.yaml

| Rule | Change | Why |
|---|---|---|
| PrometheusTimeseriesCardinality (`> 10k`) | **removed** | With kube-prometheus-stack, families like `apiserver_request_duration` buckets legitimately exceed 10k series → false positive, not actionable. |
| PrometheusTargetMissingWithWarmupTime | **removed** | Redundant with `PrometheusTargetMissing`, and its `group_left` join on `node_boot_time` is fragile. |
| everything else (incl. E2E DeadManSwitch) | kept | Standard, valuable self-monitoring. The always-firing DeadManSwitch is intentional (heartbeat). |

---

## How this was validated

```bash
# metric existence + live values
kubectl -n observability port-forward svc/observability-kube-prometh-prometheus 9090:9090
curl -s --data-urlencode 'query=count(<metric>)' localhost:9090/api/v1/query

# schema
kubectl apply --dry-run=server -f <file>.yaml
```

All new/changed expressions parse successfully and return 0 series on the
current (healthy) cluster.
