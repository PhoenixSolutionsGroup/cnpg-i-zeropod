# CRIU Compatibility Issues

This documents every CRIU issue encountered and the fix or workaround applied.

## 1. MPTCP Protocol 262 (FIXED)

**Error**: `Unsupported proto 262` during checkpoint

**Cause**: Go 1.21+ enables MPTCP (Multipath TCP, protocol 262) by default for all TCP sockets. CRIU doesn't know how to checkpoint MPTCP sockets.

**Fix**: Inject `GODEBUG=multipathtcp=0` into the postgres container. This makes Go's `net.Dial` use regular TCP (protocol 6).

**Where**: `internal/lifecycle/lifecycle.go` — appended to container env vars.

## 2. SysV Shared Memory "File exists" (FIXED)

**Error**: `Error (criu/ipc_ns.c:867): Failed to create shm set: File exists`

**Cause**: PostgreSQL always creates a 56-byte SysV shared memory segment as a postmaster "guard" segment, even with `shared_memory_type=mmap`. This is hardcoded in `src/backend/port/sysv_shmem.c`. There is no PostgreSQL configuration to disable it.

The pod's IPC namespace is shared between the pause container and the app container. When CRIU checkpoints the postgres container, the SysV segment persists in the IPC namespace (the pause container keeps it alive). When CRIU tries to restore, it calls `shmget(key, size, IPC_CREAT|IPC_EXCL)` which fails because the segment already exists.

**Fix**: Clean SysV shm segments from the pod's IPC namespace immediately after checkpoint completes, using Go syscalls directly (`setns` + `shmctl IPC_RMID`). This runs in the zeropod shim at `~/Code/zeropod-source/shim/ipc.go`.

The previous approach (exec'ing `nsenter` + `ipcrm` before restore) failed silently — likely due to PATH resolution issues in the containerd shim environment. The new approach avoids external binaries entirely.

**Why after checkpoint, not before restore**: Both timings would work, but post-checkpoint is cleaner — the process has just been frozen/killed, the segment has no attachments, and we know the OCI spec is valid. The pre-restore call is kept as a fallback.

**Verified working**: CRIU restore succeeds consistently. Restore duration ~100-400ms (vs ~500ms cold restart). Zero `RESTORE_FAILED` events, zero container restarts, data intact.

## 3. Go pidfd Process Tracking (ADDED, effectiveness unknown)

**Issue**: Go 1.23+ uses pidfds for process tracking. After CRIU restore, the Go runtime's internal pidfd state may become corrupted, causing `cmd.Wait()` to return prematurely. The CNPG instance manager thinks PostgreSQL exited and restarts it.

**Fix**: Inject `GODEBUG=pidfd=0` to force Go to use `waitpid()` instead. PIDs are preserved by CRIU.

**Status**: Added to GODEBUG alongside multipathtcp=0. CRIU restore now succeeds with this flag active. Whether it's strictly necessary hasn't been tested (removing it may or may not cause issues).

## 4. Liveness Probe Incompatibility (FIXED)

**Problem**: CNPG's default liveness probe is HTTPS on port 8000, which fails while the container is checkpointed (process frozen, port unreachable). After `failureThreshold` failures, kubelet kills the pod.

Switching to TCP on 5432 avoids the HTTPS issue but creates a new problem: the TCP probe resets zeropod's eBPF idle timer every 10s, preventing scale-down with a 30s timeout.

**Root cause**: Zeropod's eBPF socket_tracker (RUNNING state) monitors ALL TCP packets on ports-map ports. It only excludes traffic from processes matching `--probe-binary-name` (via `bpf_get_current_task()` comm name). In TC (traffic control) BPF context, `bpf_get_current_task()` doesn't reliably return the kubelet process — it often returns a kernel thread or ksoftirqd.

**Fix**: Remove the liveness probe entirely. The lifecycle hook appends a RFC 6902 `"remove"` operation targeting `/spec/containers/<idx>/livenessProbe`. CNPG's operator handles health monitoring independently via its reconciliation loop (which we disable during scale-down anyway).

**Note**: `--probe-binary-name=k3s-server` was also set in the kustomize overlay, but this alone is insufficient due to the TC context limitation.

## GODEBUG Flags Summary

The plugin injects `GODEBUG=multipathtcp=0,pidfd=0` into the postgres container:

| Flag | Go Version | Purpose |
|------|-----------|---------|
| `multipathtcp=0` | 1.21+ | Disable MPTCP (proto 262) which CRIU can't checkpoint |
| `pidfd=0` | 1.23+ | Disable pidfds, use waitpid() which survives CRIU restore |

## Zeropod Patch Details

Files modified in `~/Code/zeropod-source/`:

### `shim/ipc.go` (new file)

Uses Go syscalls directly to clean SysV shm segments. Avoids exec'ing external
binaries (`nsenter`, `ipcrm`) which failed silently in the containerd shim
environment due to PATH issues.

```go
func cleanIPCShm(ctx context.Context, spec *specs.Spec) error {
    // 1. Get IPC namespace path from OCI spec (/proc/<pause-pid>/ns/ipc)
    // 2. runtime.LockOSThread() — setns is per-thread
    // 3. unix.Setns(targetFd, CLONE_NEWIPC) — enter container's IPC ns
    // 4. Parse /proc/sysvipc/shm for segment IDs
    // 5. unix.SysvShmCtl(id, IPC_RMID, nil) for each segment
    // 6. Restore original IPC namespace via deferred setns
}
```

### `shim/checkpoint.go`

Added post-checkpoint IPC cleanup (primary call site):
```go
// After checkpoint succeeds:
if err := cleanIPCShm(ctx, c.cfg.spec); err != nil {
    log.G(ctx).Warnf("failed to clean IPC shm after checkpoint: %s", err)
}
```

### `shim/restore.go`

Pre-restore IPC cleanup kept as fallback (e.g. migration from unpatched node):
```go
if createReq.Checkpoint != "" {
    if err := cleanIPCShm(ctx, c.cfg.spec); err != nil {
        log.G(ctx).Warnf("failed to clean IPC shm segments: %s", err)
    }
}
```

### `shim/util.go` (unchanged)

`GetIPCNS(spec)` reads the IPC namespace path from the OCI spec.

Built as: `docker build --load -t ghcr.io/ctrox/zeropod-installer:patched -f cmd/installer/Dockerfile .`
