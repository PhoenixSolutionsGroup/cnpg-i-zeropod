# cnpg-i-zeropod

CNPG-I plugin that integrates [CloudNativePG](https://cloudnative-pg.io/) with [zeropod](https://github.com/ctrox/zeropod) for CRIU-based scale-to-zero PostgreSQL.

## What It Does

Three components glue CNPG to zeropod:

1. **Lifecycle Plugin** — Intercepts CNPG instance pod creation via CNPG-I gRPC hooks. Injects zeropod RuntimeClass, annotations, GODEBUG flags, and removes the liveness probe.
2. **Pooler Webhook** — A MutatingAdmissionWebhook that intercepts Pooler (PgBouncer) pod creation. CNPG-I lifecycle hooks only cover instance pods; Pooler pods are created via a Deployment and bypass the plugin system. The webhook injects the same zeropod RuntimeClass and annotations so PgBouncer gets checkpointed too.
3. **Reconciliation Controller** — Watches zeropod pod status labels. Fences checkpointed instances (via `cnpg.io/fencedInstances`), suspends ScheduledBackups, and patches CNPG and Pooler services with `publishNotReadyAddresses: true` so checkpointed pods remain in endpoints for wake-on-connect.

## Quick Start

### Prerequisites

- Kubernetes 1.35+ with [zeropod](https://github.com/ctrox/zeropod) installed
- [CloudNativePG](https://cloudnative-pg.io/) operator
- [cert-manager](https://cert-manager.io/)

### Install

```bash
# 1. Clone the repo
git clone https://github.com/PhoenixSolutionsGroup/cnpg-i-zeropod.git
cd cnpg-i-zeropod

# 2. Install zeropod
kubectl label node <node-name> zeropod.ctrox.dev/node=true
kubectl apply -k deploy/zeropod

# 3. Install the plugin
helm upgrade --install cnpg-i-zeropod charts/cnpg-i-zeropod/ \
  --namespace cnpg-system \
  --set image.repository=ghcr.io/phoenixsolutionsgroup/cnpg-i-zeropod \
  --set image.tag=dev \
  --wait

# 4. Restart CNPG operator to discover the plugin
kubectl rollout restart deployment/cnpg-controller-manager -n cnpg-system
```

### Create a cluster

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

After 300s of inactivity the pod checkpoints via CRIU. Any TCP connection to port 5432 triggers a restore — under 200ms on dedicated CPU, ~450ms on shared CPU.

### Add a Pooler (PgBouncer)

To checkpoint PgBouncer alongside PostgreSQL, create a Pooler on the same cluster:

```yaml
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

> **Important:** `server_login_retry: "0"` is required. Without it, PgBouncer caches backend connection errors for 15s (the default), turning a sub-second cold start into a ~20s wait.

The webhook automatically injects zeropod into Pooler pods — no extra annotations needed. It strips the readiness probe (which would otherwise prevent PgBouncer from checkpointing) and adds a `wake-peers` annotation so restoring PgBouncer concurrently wakes PostgreSQL.

Clients connect through the Pooler service (`my-db-pooler:5432`). When both PgBouncer and PostgreSQL are checkpointed, the first connection restores both concurrently.

### Configuration

The plugin reads from **cluster annotations** (not plugin parameters):

| Annotation                                 | Required | Default | Description                             |
| ------------------------------------------ | -------- | ------- | --------------------------------------- |
| `cnpg.io/scale-to-zero-enabled`            | yes      | —       | Set to `"true"` to enable               |
| `cnpg.io/scale-to-zero-inactivity-seconds` | no       | `300`   | Seconds of inactivity before checkpoint |

## Architecture

```
┌─────────────────────────────────────────────────┐
│           Zeropod (installed separately)         │
│                                                  │
│  Shim: CRIU checkpoint/restore, eBPF tracker     │
│  Manager DaemonSet: metrics, pod labels          │
│    sets label: status.zeropod.ctrox.dev/postgres │
│      = "SCALED_DOWN" or "RUNNING"                │
└────────────────────┬────────────────────────────┘
                     │ pod label change
┌────────────────────▼────────────────────────────┐
│        Reconciliation Controller                 │
│                                                  │
│  On instance SCALED_DOWN:                        │
│    → add to cnpg.io/fencedInstances              │
│    → suspend ScheduledBackups                    │
│    → patch -rw/-ro/-r svc publishNotReadyAddr    │
│  On instance RUNNING:                            │
│    → remove from cnpg.io/fencedInstances         │
│    → resume ScheduledBackups                     │
│  On pooler SCALED_DOWN:                          │
│    → patch pooler svc publishNotReadyAddresses   │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│        Lifecycle Plugin (CNPG-I gRPC)            │
│                                                  │
│  On instance pod creation:                       │
│    → inject runtimeClassName: zeropod            │
│    → inject zeropod annotations                  │
│    → inject GODEBUG=multipathtcp=0,pidfd=0       │
│    → remove liveness probe (RFC 6902 remove op)  │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│        Pooler Webhook (MutatingAdmission)        │
│                                                  │
│  On Pooler (PgBouncer) pod creation:             │
│    → inject runtimeClassName: zeropod            │
│    → inject zeropod annotations + wake-peers     │
│    → remove liveness + readiness probes          │
│    (no GODEBUG — PgBouncer is C, not Go)         │
└─────────────────────────────────────────────────┘
```

## Documentation

- [docs/deployment.md](docs/deployment.md) — Full deployment guide
- [docs/architecture.md](docs/architecture.md) — How the components work together
- [docs/criu-issues.md](docs/criu-issues.md) — CRIU compatibility issues and fixes
- [docs/status.md](docs/status.md) — Current project status and benchmarks
- [docs/debugging.md](docs/debugging.md) — How to debug checkpoint/restore issues
