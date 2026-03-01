# Debugging Guide

## Pod Not Scaling Down

### Check zeropod status label
```bash
kubectl get pod <pod> -o jsonpath='{.metadata.labels.status\.zeropod\.ctrox\.dev/postgres}'
```

### Check RuntimeClass is set
```bash
kubectl get pod <pod> -o jsonpath='{.spec.runtimeClassName}'
# Should be: zeropod
```

### Check liveness probe is removed
```bash
kubectl get pod <pod> -o jsonpath='{.spec.containers[0].livenessProbe}'
# Should be empty
```

If the liveness probe exists, it's resetting the eBPF idle timer (TCP on 5432) or killing the pod (HTTPS on 8000). The lifecycle hook may not have run — check the cluster annotations.

### Check cluster annotations
```bash
kubectl get cluster <cluster> -o jsonpath='{.metadata.annotations}'
```

Must include `cnpg.io/scale-to-zero-enabled: "true"`. Without this, the lifecycle hook returns an empty patch.

### Check GODEBUG is injected
```bash
kubectl get pod <pod> -o jsonpath='{.spec.containers[0].env[?(@.name=="GODEBUG")].value}'
# Should be: multipathtcp=0,pidfd=0
```

### Check zeropod manager logs
```bash
kubectl -n zeropod-system logs daemonset/zeropod-node --tail=50
```

Look for status events like `phase=SCALED_DOWN` or `phase=RUNNING`.

## CRIU Checkpoint Fails

### Check zeropod manager logs for checkpoint errors
```bash
kubectl -n zeropod-system logs daemonset/zeropod-node | grep -i "checkpoint\|CHECKPOINT_FAILED"
```

### Common checkpoint errors

**Unsupported proto 262**: MPTCP not disabled. Check GODEBUG env var includes `multipathtcp=0`.

## CRIU Restore Fails

### Check restore error details
```bash
kubectl -n zeropod-system logs daemonset/zeropod-node | grep -A20 "RESTORE_FAILED"
```

### Check the shim's log.json
The shim writes runc/CRIU output to `log.json` in the container's task directory:

```bash
# Get the container ID
CONTAINER_ID=$(kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|containerd://||')

# Read from a privileged debug pod
kubectl run debug --rm -i --restart=Never --image=alpine:3.19 \
  --overrides='{"spec":{"containers":[{"name":"d","image":"alpine:3.19","command":["cat","/host/run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/'$CONTAINER_ID'/log.json"],"securityContext":{"privileged":true},"volumeMounts":[{"name":"h","mountPath":"/host"}]}],"volumes":[{"name":"h","hostPath":{"path":"/"}}]}}'
```

### Check if the shim binary is patched
```bash
# From a privileged pod
strings /host/var/lib/rancher/k3s/agent/containerd/bin/containerd-shim-zeropod-v2 | grep cleanIPCShm
```

### Common restore errors

**Failed to create shm set: File exists**: SysV shm segment persists in pod IPC namespace. See [criu-issues.md](criu-issues.md#2-sysv-shared-memory-file-exists-blocking--not-fixed).

**criu failed: type RESTORE errno 0**: Generic CRIU restore failure. Check the full CRIU log in `log.json` for specific error.

## Plugin Not Applying Patches

### Check plugin is registered
```bash
kubectl get cluster <cluster> -o jsonpath='{.status.pluginStatus}' | python3 -m json.tool
```

Should show `cnpg-i-zeropod.io` with capability `TYPE_LIFECYCLE_SERVICE`.

### Check plugin logs
```bash
kubectl -n cnpg-system logs deployment/cnpg-i-zeropod --tail=20
```

Should show `"Starting plugin" name="cnpg-i-zeropod.io"`.

### Check CNPG operator logs for plugin errors
```bash
kubectl -n cnpg-system logs deployment/cnpg-controller-manager | grep -i "plugin\|error.*zeropod"
```

Common issue: `connection refused` — plugin pod restarted and CNPG hasn't reconnected yet. It retries automatically.

### Plugin name mismatch
The plugin registers as `cnpg-i-zeropod.io`. The cluster spec must use this exact name:
```yaml
plugins:
  - name: cnpg-i-zeropod.io  # NOT cnpg-i-zeropod.leonardoce.io
```

## Controller Not Toggling Reconciliation

### Check controller logs
```bash
kubectl -n cnpg-system logs deployment/cnpg-i-zeropod-controller --tail=20
```

### Check if reconciliation is disabled
```bash
kubectl get cluster <cluster> -o jsonpath='{.metadata.annotations.cnpg\.io/reconciliationLoop}'
# "disabled" when scaled down, absent when running
```

### Manually toggle for testing
```bash
# Disable
kubectl annotate cluster <cluster> cnpg.io/reconciliationLoop=disabled

# Enable
kubectl annotate cluster <cluster> cnpg.io/reconciliationLoop-
```

## Benchmark Script

`scripts/bench-coldstart.sh` measures warm and cold query latencies using a persistent psql client pod. It creates a temporary CNPG cluster with 10s scaledown, inserts test data, and runs N warm queries followed by N cold queries (waiting for scale-down between each).

```bash
./scripts/bench-coldstart.sh
```
