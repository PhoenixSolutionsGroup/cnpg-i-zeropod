# Deployment Guide

## Prerequisites

Install these before deploying the plugin:

### 1. cert-manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=120s
```

### 2. CloudNativePG operator

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.26/releases/cnpg-1.26.0.yaml
kubectl wait --for=condition=Available deployment/cnpg-controller-manager \
  -n cnpg-system --timeout=120s
```

### 3. Zeropod

Label nodes that should run zeropod:

```bash
kubectl label node <node-name> zeropod.ctrox.dev/node=true
```

Install zeropod using the kustomize overlay included in this repo. This overlay adds k3s support, status-labels, and tracker-ignore-localhost:

```bash
kubectl apply -k https://github.com/PhoenixSolutionsGroup/cnpg-i-zeropod/deploy/zeropod
```

> **Note**: `deploy/zeropod/kustomization.yaml` currently points to a fork with a [SysV IPC fix](criu-issues.md) required for PostgreSQL. Once this fix is merged upstream, the overlay will point back to `ctrox/zeropod` directly.

Wait for zeropod to be ready (this restarts containerd on labeled nodes):

```bash
kubectl wait --for=condition=Ready pod -l app=zeropod-node -n zeropod-system --timeout=300s
```

## Install the plugin

```bash
helm upgrade --install cnpg-i-zeropod charts/cnpg-i-zeropod/ \
  --namespace cnpg-system \
  --set image.repository=ghcr.io/phoenixsolutionsgroup/cnpg-i-zeropod \
  --set image.tag=dev \
  --wait --timeout=120s
```

Restart the CNPG operator so it discovers the plugin:

```bash
kubectl rollout restart deployment/cnpg-controller-manager -n cnpg-system
kubectl rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=60s
```

## Create a CNPG cluster

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: my-db
  annotations:
    cnpg.io/scale-to-zero-enabled: "true"
    cnpg.io/scale-to-zero-inactivity-seconds: "300"
spec:
  instances: 1
  enableSuperuserAccess: true
  plugins:
    - name: cnpg-i-zeropod.io
  storage:
    size: 1Gi
```

The plugin injects the zeropod RuntimeClass, annotations, GODEBUG flags, and removes the liveness probe. After 300s of inactivity the pod checkpoints; any TCP connection to port 5432 triggers restore.

## Using with PgBouncer (recommended)

A CNPG Pooler in front of the cluster absorbs the CRIU restore latency so clients never see a failed connection — just a brief wait on cold start.

**Important:** Set `server_login_retry: "1"` — PgBouncer retries the backend every 1s while holding client connections open. The default (15s) adds unacceptable latency. Combined with `query_wait_timeout: "30"`, clients wait transparently while PG restores.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: my-db
  annotations:
    cnpg.io/scale-to-zero-enabled: "true"
    cnpg.io/scale-to-zero-inactivity-seconds: "300"
spec:
  instances: 1
  enableSuperuserAccess: true
  plugins:
    - name: cnpg-i-zeropod.io
  postgresql:
    parameters:
      shared_memory_type: mmap
      dynamic_shared_memory_type: posix
      shared_buffers: "64MB"
  storage:
    size: 1Gi
---
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: my-db-pooler
spec:
  cluster:
    name: my-db
  instances: 1
  type: rw
  pgbouncer:
    poolMode: session
    parameters:
      max_client_conn: "100"
      default_pool_size: "10"
      server_login_retry: "1"
      query_wait_timeout: "30"
```

Connect via the pooler service (`my-db-pooler`) instead of the cluster services directly. The pooler pod will also be checkpointed by zeropod and restored on incoming connections.

## Verify

```bash
# Check zeropod runtime was injected
kubectl get pod my-db-1 -o jsonpath='{.spec.runtimeClassName}'
# Should output: zeropod

# Watch for scaledown after inactivity timeout
kubectl get pod my-db-1 --show-labels -w
# Look for: status.zeropod.ctrox.dev/postgres=SCALED_DOWN

# Trigger restore via TCP
kubectl exec -it my-db-1 -c postgres -- psql -U postgres -c "SELECT 1;"
```

## Multi-container BaaS pod (PG + PgBouncer + Kratos + Keto)

For a BaaS free/shared tier, pack all services into a single zeropod pod. Each container checkpoints/restores independently — incoming traffic on any port wakes only the containers needed.

### Architecture

```
Client :4433 → [zeropod] → Kratos → PgBouncer(:6432) → Postgres(:5432)
Client :4466 → [zeropod] → Keto    → PgBouncer(:6432) → Postgres(:5432)
Client :6432 → [zeropod] → PgBouncer → Postgres(:5432)
Client :5432 → [zeropod] → Postgres (direct)
```

All containers share `localhost`. When idle, all checkpoint independently. A request to any port triggers a wake chain — e.g., a Kratos API call wakes Kratos, which connects to PgBouncer (waking it), which connects to PG (waking it).

### Zeropod annotations

```yaml
annotations:
  zeropod.ctrox.dev/ports-map: "postgres=5432;pgbouncer=6432;kratos=4433;keto=4466"
  zeropod.ctrox.dev/container-names: "postgres,pgbouncer,kratos,keto"
  zeropod.ctrox.dev/scaledown-duration: "300s"
  zeropod.ctrox.dev/proxy-timeout: "30s"
  zeropod.ctrox.dev/connect-timeout: "30s"
  zeropod.ctrox.dev/cpu-requests: '{"postgres":"0","pgbouncer":"0","kratos":"0","keto":"0"}'
  zeropod.ctrox.dev/memory-requests: '{"postgres":"0","pgbouncer":"0","kratos":"0","keto":"0"}'
```

- **ports-map**: semicolons between containers, commas for multiple ports per container
- **cpu/memory-requests**: zeroed so the scheduler doesn't count checkpointed pods against node capacity
- **scaledown-duration**: how long idle before checkpoint (300s for prod, 5s for testing)

### PgBouncer config for internal services

Route Kratos/Keto through PgBouncer in `transaction` mode to minimize PG backend connections (critical at 250+ pods per node where each PG has a 256Mi memory limit):

```ini
[databases]
postgres = host=127.0.0.1 port=5432 dbname=postgres
kratos = host=127.0.0.1 port=5432 dbname=kratos
keto = host=127.0.0.1 port=5432 dbname=keto

[pgbouncer]
pool_mode = transaction
default_pool_size = 5
max_client_conn = 200
```

Point all service DSNs at PgBouncer (`localhost:6432`) instead of PG directly:
```
postgres://postgres:pass@127.0.0.1:6432/kratos?sslmode=disable
postgres://postgres:pass@127.0.0.1:6432/keto?sslmode=disable
```

### Go services (Kratos, Keto, etc.)

Go binaries need CRIU-compatible runtime flags:
```yaml
env:
  - name: GODEBUG
    value: "multipathtcp=0,pidfd=0"
```

Services that connect to PG should retry on startup (PG may still be initializing):
```bash
n=0
until [ $n -ge 60 ]; do
  kratos migrate sql --yes "$DSN" && break
  n=$((n + 1))
  sleep 2
done
exec kratos serve all -c /etc/kratos/kratos.yml
```

### PG init databases

Mount an init SQL script to create service databases:
```yaml
volumeMounts:
  - name: pg-init
    mountPath: /docker-entrypoint-initdb.d
---
configMap:
  name: pg-init
  data:
    init.sql: "CREATE DATABASE kratos; CREATE DATABASE keto;"
```

### Benchmarks (2 vCPU / 2GB node, VKE)

Cold wake latency with all 4 containers checkpointed (SCALEDOWN=5s):

| Path | p50 | Steady state |
|------|-----|-------------|
| Direct PG | ~555ms | 550-560ms |
| PgBouncer → PG | ~560ms | 554-660ms |
| Kratos → PgBouncer → PG | ~660ms | 659-738ms |
| Keto → PgBouncer → PG | ~705ms | 705-918ms |

3-hop chain adds ~100-150ms over direct PG. All responses include real DB data (Kratos returns registration flows, Keto returns relation tuples).

### Test script

```bash
SCALEDOWN_SECONDS=5 bash scripts/test-multi-container.sh
```

### Adding more services

To add PostgREST, custom API, etc. to the pod:
1. Add the container to the pod spec
2. Add its port to `ports-map` (e.g., `postgrest=3000`)
3. Add to `container-names`, `cpu-requests`, `memory-requests`
4. Add its database to PgBouncer `[databases]` if it uses PG
5. Set `GODEBUG=multipathtcp=0,pidfd=0` if it's a Go binary

## Auto-deploy zeropod on new nodes (VKE)

By default, zeropod's DaemonSet uses `nodeSelector: zeropod.ctrox.dev/node=true`, requiring manual labeling of each new node. For autoscaled node pools, replace this with the VKE pool label so new nodes get zeropod automatically.

The `deploy/zeropod-vke/` kustomization patches the DaemonSet to target a specific VKE node pool:

```yaml
# deploy/zeropod-vke/kustomization.yaml (excerpt)
patches:
  - target:
      kind: DaemonSet
      name: zeropod-node
    patch: |-
      - op: replace
        path: /spec/template/spec/nodeSelector
        value:
          vke.vultr.com/node-pool: "local-nvme-2-2"
```

This replaces the upstream `zeropod.ctrox.dev/node=true` selector with `vke.vultr.com/node-pool`, which VKE sets automatically on every node in the pool. When the cluster autoscaler adds a node to the pool, the DaemonSet deploys zeropod with no manual intervention.

To use a different pool, change `local-nvme-2-2` to your pool name:
```bash
kubectl get nodes -L vke.vultr.com/node-pool
```

## Max density: NFS shared storage

To pack 100+ instances on a single node, use NFS on a single large block storage volume instead of one PVC per instance (most providers limit volumes per node).

1. Create one large PVC (e.g. 100Gi) using block storage
2. Deploy an NFS server pod mounting that PVC
3. Install [nfs-subdir-external-provisioner](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner) — creates a subdirectory per PVC
4. Set `storageClass: nfs-client` in the CNPG cluster spec

For benchmarking or small deployments, `local-path` (Rancher) works if the node has enough local disk.

## Dev/test bootstrap

For local development on a single-node k3s machine, the bootstrap script handles all prerequisites + build + deploy:

```bash
sudo bash scripts/bootstrap.sh
```

See [the bootstrap script](../scripts/bootstrap.sh) for details.
