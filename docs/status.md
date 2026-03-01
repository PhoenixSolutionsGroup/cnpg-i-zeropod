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

| Metric | Value |
|--------|-------|
| Warm query latency | 43-46ms (avg 44ms) |
| CRIU restore duration | ~100-400ms |
| Checkpoint duration | ~400-470ms |

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
