# Architecture

## Components

### 1. Lifecycle Plugin (`internal/lifecycle/lifecycle.go`)

A CNPG-I gRPC plugin that intercepts pod creation. When CNPG creates a pod for a cluster with `cnpg.io/scale-to-zero-enabled: "true"`, the hook returns a JSON patch that:

1. Sets `spec.runtimeClassName: zeropod`
2. Adds zeropod annotations:
   - `zeropod.ctrox.dev/ports-map: "postgres=5432"`
   - `zeropod.ctrox.dev/container-names: "postgres"`
   - `zeropod.ctrox.dev/scaledown-duration: "<duration>"`
3. Injects `GODEBUG=multipathtcp=0,pidfd=0` env var (CRIU compatibility)
4. Appends a RFC 6902 `"remove"` op to strip the liveness probe

**Why remove the liveness probe**: CNPG adds probes AFTER calling the lifecycle hook, so the pod we receive has no probes yet. We append a forward-looking remove op. Any probe type is incompatible with zeropod:
- TCP on 5432: resets the eBPF idle timer every 10s, prevents scale-down
- HTTPS on 8000: fails while checkpointed (process frozen), kills the pod

CNPG's operator handles health monitoring independently via its reconciliation loop.

### 2. Pooler Webhook (`internal/webhook/webhook.go`)

A MutatingAdmissionWebhook that intercepts Pooler (PgBouncer) pod creation. CNPG-I lifecycle hooks only cover instance pods; Pooler pods are created via a Deployment and bypass the plugin system. The webhook:

1. Sets `spec.runtimeClassName: zeropod`
2. Adds zeropod annotations (ports-map, container-names, scaledown-duration, cpu/memory requests)
3. Adds `wake-peers` annotation with the `-rw` service ClusterIP so restoring PgBouncer concurrently wakes PostgreSQL
4. Removes both liveness and readiness probes — the readiness probe (TCP on 5432 every 10s) resets zeropod's eBPF idle timer, preventing PgBouncer from ever checkpointing

### 3. Reconciliation Controller (`internal/controller/reconciler.go`)

A controller-runtime reconciler that watches pods with both `cnpg.io/cluster` label and `zeropod.ctrox.dev/ports-map` annotation. When zeropod's manager DaemonSet updates the pod label `status.zeropod.ctrox.dev/<container>`:

**Instance pods:**
- **SCALED_DOWN**: Adds the pod to `cnpg.io/fencedInstances` on the Cluster (so CNPG skips it when waiting for pods to be ready), suspends ScheduledBackups, and patches the CNPG services (`-rw`, `-ro`, `-r`) with `publishNotReadyAddresses: true` so checkpointed pods remain in service endpoints for wake-on-connect.
- **RUNNING**: Removes the pod from `cnpg.io/fencedInstances`, resumes ScheduledBackups.

**Pooler pods:**
- **SCALED_DOWN**: Patches the Pooler's service with `publishNotReadyAddresses: true`.

Without `publishNotReadyAddresses`, checkpointed pods are removed from service endpoints (they're not Ready), so no TCP traffic can reach zeropod to trigger a restore — causing a permanent deadlock.

### 4. Zeropod Kustomize Overlay (`deploy/zeropod/kustomization.yaml`)

Extends the upstream zeropod k3s config with:
- `tracker-ignore-localhost`: eBPF skips localhost connections (CNPG instance manager → PG)
- `status-labels`: Enables pod status labels that the controller watches
- `probe-binary-name=k3s-server`: Tells eBPF to identify kubelet traffic by process comm name
- Patched installer image tag for the IPC shm fix (see [criu-issues.md](criu-issues.md))

## How Zeropod Works (internals relevant to this project)

### Checkpoint Flow
1. eBPF socket_tracker monitors TCP packets on ports-map ports (5432)
2. No non-kubelet, non-localhost traffic for `scaledown-duration` → trigger checkpoint
3. CRIU snapshots the entire container process tree to `/run/zeropod/{id}/snapshots/`
4. Container process is killed, pod stays "Running" in K8s
5. Zeropod sets pod label `status.zeropod.ctrox.dev/postgres=SCALED_DOWN`

### Restore Flow
1. TCP connection arrives on port 5432
2. Zeropod's activator proxy holds the connection
3. Zeropod calls `p.Start(ctx)` which triggers CRIU restore (or cold restart on failure)
4. On success: process resumes from checkpoint, connection forwarded
5. On failure: `DisableCheckpointing = true`, retry without checkpoint (cold restart)
6. Zeropod sets pod label `status.zeropod.ctrox.dev/postgres=RUNNING`

### eBPF Idle Timer (RUNNING state)
- Monitors ALL TCP packets on ports-map ports
- Resets idle timer for any packet NOT from kubelet and NOT from localhost
- Kubelet detection: `bpf_get_current_task()` comm name matching against `--probe-binary-name`
- **Limitation**: In TC (traffic control) BPF context, `bpf_get_current_task()` doesn't reliably return the kubelet process. This is why we remove the liveness probe entirely rather than relying on kubelet detection.

### Probe Handling (SCALED_DOWN state only)
- Userspace activator proxy detects TCP connect-close patterns (health probes)
- HTTP kube-probe/ headers get synthetic 200 responses
- This only runs when the pod is scaled down — NOT relevant to the idle timer problem

## File Layout

```
cnpg-i-zeropod/
├── main.go                              # Cobra root: "plugin" + "controller" subcommands
├── cmd/
│   ├── plugin/plugin.go                 # CNPG-I gRPC server setup
│   └── controller/controller.go         # Controller-runtime manager setup
├── internal/
│   ├── lifecycle/lifecycle.go           # Instance pod mutation (RuntimeClass, annotations, probe removal)
│   ├── webhook/webhook.go              # Pooler pod mutation (zeropod injection, probe removal, wake-peers)
│   └── controller/reconciler.go         # Fencing, backup suspend/resume, publishNotReadyAddresses
├── charts/cnpg-i-zeropod/              # Helm chart
│   └── templates/
│       ├── deployment.yaml              # Plugin deployment
│       ├── controller-deployment.yaml   # Controller deployment
│       ├── controller-rbac.yaml         # ClusterRole for pods, services, clusters, scheduledbackups
│       ├── service.yaml                 # Plugin gRPC service
│       └── tls-secret.yaml              # mTLS certs for CNPG-I
├── deploy/zeropod/kustomization.yaml    # Zeropod k3s overlay
├── scripts/bench-coldstart.sh           # Benchmark script
└── Dockerfile
```

## Deployment Topology

Both the plugin and controller run as separate Deployments in `cnpg-system` namespace, using the same Docker image with different subcommands:

- `cnpg-i-zeropod plugin` — gRPC server on :9090 with mTLS
- `cnpg-i-zeropod controller` — controller-runtime manager

The CNPG operator discovers the plugin via the Kubernetes Service `cnpg-i-zeropod` in `cnpg-system`.
