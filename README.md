# cnpg-i-zeropod

CNPG-I plugin that integrates [CloudNativePG](https://cloudnative-pg.io/) with [zeropod](https://github.com/ctrox/zeropod) for CRIU-based scale-to-zero PostgreSQL.

## What It Does

Two components glue CNPG to zeropod:

1. **Lifecycle Plugin** — Intercepts CNPG pod creation via CNPG-I gRPC hooks. Injects zeropod RuntimeClass, annotations, GODEBUG flags, and removes the liveness probe.
2. **Reconciliation Controller** — Watches zeropod pod status labels. Disables the CNPG operator's reconciliation loop and suspends ScheduledBackups when a pod is checkpointed, re-enables them on restore.

## Quick Start

### Prerequisites

- Kubernetes 1.35+ with [zeropod](https://github.com/ctrox/zeropod) installed
- [CloudNativePG](https://cloudnative-pg.io/) operator
- [cert-manager](https://cert-manager.io/)

### Install

```bash
# 1. Install zeropod
kubectl label node <node-name> zeropod.ctrox.dev/node=true
kubectl apply -k https://github.com/PhoenixSolutionsGroup/cnpg-i-zeropod/deploy/zeropod

# 2. Install the plugin
helm upgrade --install cnpg-i-zeropod charts/cnpg-i-zeropod/ \
  --namespace cnpg-system \
  --set image.repository=ghcr.io/phoenixsolutionsgroup/cnpg-i-zeropod \
  --set image.tag=dev \
  --wait

# 3. Restart CNPG operator to discover the plugin
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

After 300s of inactivity the pod checkpoints via CRIU. Any TCP connection to port 5432 triggers a restore in ~400ms.

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
│  On SCALED_DOWN:                                 │
│    → set cnpg.io/reconciliationLoop: disabled    │
│    → suspend ScheduledBackups                    │
│  On RUNNING:                                     │
│    → remove cnpg.io/reconciliationLoop           │
│    → resume ScheduledBackups                     │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│        Lifecycle Plugin (CNPG-I gRPC)            │
│                                                  │
│  On CNPG pod creation:                           │
│    → inject runtimeClassName: zeropod            │
│    → inject zeropod annotations                  │
│    → inject GODEBUG=multipathtcp=0,pidfd=0       │
│    → remove liveness probe (RFC 6902 remove op)  │
└─────────────────────────────────────────────────┘
```

## Documentation

- [docs/deployment.md](docs/deployment.md) — Full deployment guide
- [docs/architecture.md](docs/architecture.md) — How the components work together
- [docs/criu-issues.md](docs/criu-issues.md) — CRIU compatibility issues and fixes
- [docs/status.md](docs/status.md) — Current project status and benchmarks
- [docs/debugging.md](docs/debugging.md) — How to debug checkpoint/restore issues
