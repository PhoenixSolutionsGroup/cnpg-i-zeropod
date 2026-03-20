# Project Status

## What Works

- **Lifecycle plugin**: Injects zeropod RuntimeClass, annotations, GODEBUG env, removes liveness probe via RFC 6902 JSON patch
- **Reconciliation controller**: Watches zeropod status labels, toggles CNPG reconciliation loop and ScheduledBackup suspend/resume
- **Checkpoint**: CRIU checkpoint succeeds (with `GODEBUG=multipathtcp=0,pidfd=0`)
- **Scale-down**: Pod correctly scales down after inactivity timeout (configurable via cluster annotation)
- **CRIU restore**: True CRIU restore works (SysV shm fix applied). PG resumes from checkpoint without WAL recovery
- **Cold restart fallback**: If CRIU restore fails, zeropod falls back to cold restart. PG does WAL recovery
- **Data integrity**: Data survives checkpoint/restore cycles
- **Liveness probe removal**: RFC 6902 "remove" op strips the probe CNPG adds after the lifecycle hook

## Current Benchmarks (true CRIU restore)

Benchmarked on Vultr VKE (Sydney region) using `scripts/bench-coldstart.sh` with a single-instance CNPG cluster, PgBouncer pooler, and 15s inactivity timeout.

### Dedicated CPU + Local NVMe (vx1-g-2c-8g-120s)

| Metric | Min | Max | Avg |
|--------|-----|-----|-----|
| Warm query (fresh psql + TLS) | 27ms | 31ms | **28ms** |
| Cold start: PG direct | 163ms | 190ms | **172ms** |
| Cold start: Pooler + PG | 190ms | 205ms | **195ms** |
| CRIU restore (shim-level) | 111ms | 127ms | **~115ms** |

### Shared CPU + Block Storage SSD (vc2-2c-4gb)

| Metric | Min | Max | Avg |
|--------|-----|-----|-----|
| Warm query (fresh psql + TLS) | 79ms | 83ms | **81ms** |
| Cold start: PG direct | 406ms | 478ms | **432ms** |
| Cold start: Pooler + PG | 469ms | 513ms | **484ms** |
| CRIU restore (shim-level) | — | — | **~278ms** |

### Key Findings

- **CPU is the bottleneck, not storage.** Shared CPU + local SSD (~432ms) matches shared CPU + block storage (~450ms). Dedicated CPU cuts cold start by 2.5x.
- **CRIU restore is CPU-bound.** Dominated by kernel operations (process tree forking, namespace restoration, FD table rebuild), not disk I/O. Checkpoint images are small enough that even network-attached SSD reads them fast.
- **Pooler overhead is minimal.** Wake-peers annotation triggers concurrent PgBouncer + PG restore, adding only ~20ms over direct PG cold start.
- **Warm query includes connection setup.** Each measurement creates a fresh psql process + TLS handshake + PG auth, unlike benchmarks that measure queries on established connections.

## Resolved: SysV Shared Memory (was blocking)

PostgreSQL creates a 56-byte SysV guard segment even with `shared_memory_type=mmap` (hardcoded in `src/backend/port/sysv_shmem.c`). This persisted in the pod's IPC namespace across checkpoint/restore, causing CRIU's `shmget(IPC_CREAT|IPC_EXCL)` to fail with `EEXIST`.

**Fix**: Zeropod shim patch (`~/Code/zeropod-source/shim/ipc.go`) uses Go syscalls (`setns` + `shmctl IPC_RMID`) to clean SysV segments from the pod's IPC namespace after checkpoint. The previous exec-based approach (`nsenter` + `ipcrm`) failed silently due to PATH issues in the containerd shim environment. See [criu-issues.md](criu-issues.md) for details.

## Plugin Configuration

The lifecycle hook reads from **cluster annotations** (not plugin parameters):

```yaml
metadata:
  annotations:
    cnpg.io/scale-to-zero-enabled: "true"          # required, enables the hook
    cnpg.io/scale-to-zero-inactivity-seconds: "30"  # optional, default 300s
```

The cluster must also reference the plugin:

```yaml
spec:
  plugins:
    - name: cnpg-i-zeropod.io
```

**Known gotcha**: If you use `plugins.parameters.scaledownDuration` instead of the annotation, the hook silently does nothing (returns empty patch). The hook code checks `cluster.Annotations["cnpg.io/scale-to-zero-enabled"]`.

## Plugin Name

The plugin registers as `cnpg-i-zeropod.io` (see `cmd/plugin/plugin.go`). The cluster spec must use this exact name.
