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

**Important:** Set `server_login_retry: "0"` — without this, PgBouncer caches backend connection errors for 15s (the default), turning a sub-second cold start into a ~20s wait.

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
      server_login_retry: "0"
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

## Dev/test bootstrap

For local development on a single-node k3s machine, the bootstrap script handles all prerequisites + build + deploy:

```bash
sudo bash scripts/bootstrap.sh
```

See [the bootstrap script](../scripts/bootstrap.sh) for details.
