#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# bench-concurrent.sh — Concurrent cold start benchmark for CNPG + zeropod
#
# Creates N clusters (with optional poolers), checkpoints them all, then wakes
# them using the Go bench binary (cmd/bench) for accurate in-process timing.
#
# Usage:
#   INSTANCES=10 OFFSET_MS=0 POOLER=1 bash scripts/bench-concurrent.sh
#
# Environment:
#   INSTANCES          Number of PG instances to create (default: 5)
#   OFFSET_MS          Stagger between wake calls in ms (default: 0 = all at once)
#   POOLER             Set to 1 to create+use PgBouncer poolers (default: 0)
#   SCALEDOWN_SECONDS  Idle timeout before checkpoint (default: 1)
#   RESTORE_TIMEOUT    Zeropod restore retry timeout (default: 10s)
#   ITERATIONS         Number of wake/checkpoint cycles (default: 3)
#   WAIT_READY         Seconds to wait between cycles for re-checkpoint (default: 10)
#   NAMESPACE          Kubernetes namespace (default: default)
#   NODE_POOL          Pin to a specific VKE node pool (default: "")
# ---------------------------------------------------------------------------

info()  { printf '\033[1;34m[BENCH]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[BENCH]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[BENCH]\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31m[BENCH]\033[0m %s\n' "$*"; }

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
KUBECTL="${KUBECTL:-kubectl}"

INSTANCES="${INSTANCES:-5}"
OFFSET_MS="${OFFSET_MS:-0}"
POOLER="${POOLER:-0}"
SCALEDOWN_SECONDS="${SCALEDOWN_SECONDS:-1}"
RESTORE_TIMEOUT="${RESTORE_TIMEOUT:-10s}"
ITERATIONS="${ITERATIONS:-3}"
WAIT_READY="${WAIT_READY:-$((SCALEDOWN_SECONDS + 5))}"
NAMESPACE="${NAMESPACE:-default}"
NODE_POOL="${NODE_POOL:-}"
STORAGE_CLASS="${STORAGE_CLASS:-local-path}"
PREFIX="cb"
BENCH_POD="bench-runner"
BENCH_IMAGE="${BENCH_IMAGE:-ghcr.io/phoenixsolutionsgroup/cnpg-bench:dev}"

cleanup() {
  info "Cleaning up..."
  $KUBECTL delete pod "$BENCH_POD" -n "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
  for i in $(seq -w 1 "$INSTANCES"); do
    $KUBECTL delete pooler "${PREFIX}-${i}-pooler" -n "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
    $KUBECTL delete cluster "${PREFIX}-${i}" -n "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
  done
  sleep 5
  for i in $(seq -w 1 "$INSTANCES"); do
    $KUBECTL delete pvc "${PREFIX}-${i}-1" -n "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
  done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Build bench binary and deploy into runner pod
# ---------------------------------------------------------------------------
BENCH_BIN="$(cd "$(dirname "$0")/.." && pwd)/bin/bench"
if [ ! -f "$BENCH_BIN" ]; then
  info "Building bench binary..."
  (cd "$(dirname "$0")/.." && CGO_ENABLED=0 go build -ldflags="-s -w" -o bin/bench ./cmd/bench/) || {
    fail "Failed to build bench binary. Run: CGO_ENABLED=0 go build -o bin/bench ./cmd/bench/"
    exit 1
  }
  ok "Built $BENCH_BIN"
fi

info "Deploying bench runner pod..."
$KUBECTL delete pod "$BENCH_POD" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
sleep 2
$KUBECTL run "$BENCH_POD" --image=alpine:latest --restart=Never -n "$NAMESPACE" --command -- sleep 7200
$KUBECTL wait --for=condition=Ready "pod/$BENCH_POD" -n "$NAMESPACE" --timeout=60s
$KUBECTL cp "$BENCH_BIN" "${NAMESPACE}/${BENCH_POD}:/bench"
ok "Bench runner ready"

# ---------------------------------------------------------------------------
# 2. Create clusters (and poolers)
# ---------------------------------------------------------------------------
info "Creating ${INSTANCES} clusters (pooler=${POOLER}, scaledown=${SCALEDOWN_SECONDS}s)..."

for i in $(seq -w 1 "$INSTANCES"); do
  name="${PREFIX}-${i}"
  $KUBECTL apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
  annotations:
    cnpg.io/scale-to-zero-enabled: "true"
    cnpg.io/scale-to-zero-inactivity-seconds: "${SCALEDOWN_SECONDS}"
    cnpg.io/scale-to-zero-restore-timeout: "${RESTORE_TIMEOUT}"
spec:
  instances: 1
  enableSuperuserAccess: true
  plugins:
    - name: cnpg-i-zeropod.io
  postgresql:
    parameters:
      shared_memory_type: mmap
      dynamic_shared_memory_type: posix
      shared_buffers: "16MB"
  resources:
    limits:
      memory: "256Mi"
  storage:
    size: 1Gi
$([ -n "$STORAGE_CLASS" ] && echo "    storageClass: ${STORAGE_CLASS}")
$([ -n "$NODE_POOL" ] && cat <<AFFINITY
  affinity:
    nodeSelector:
      vke.vultr.com/node-pool: ${NODE_POOL}
AFFINITY
)
EOF

  if [ "$POOLER" = "1" ]; then
    $KUBECTL apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: ${name}-pooler
  namespace: ${NAMESPACE}
spec:
  cluster:
    name: ${name}
  instances: 1
  type: rw
  pgbouncer:
    poolMode: session
    parameters:
      max_client_conn: "100"
      default_pool_size: "10"
      server_login_retry: "0"
      query_wait_timeout: "30"
EOF
  fi
done 2>&1 | grep -c "created" || true
ok "Clusters created"

# ---------------------------------------------------------------------------
# 3. Wait for all to checkpoint
# ---------------------------------------------------------------------------
info "Waiting for all instances to checkpoint..."
timeout=600
end=$((SECONDS + timeout))
last_msg=""
while [ $SECONDS -lt $end ]; do
  $KUBECTL delete pods -n "$NAMESPACE" --field-selector=status.phase=Succeeded --ignore-not-found 2>/dev/null > /dev/null

  pg_total=$($KUBECTL get pods -n "$NAMESPACE" -l cnpg.io/podRole=instance --no-headers 2>/dev/null | wc -l)
  pg_running=$($KUBECTL get pods -n "$NAMESPACE" -l cnpg.io/podRole=instance \
    -o jsonpath='{range .items[*]}{.metadata.labels.status\.zeropod\.ctrox\.dev/postgres}{"\n"}{end}' 2>/dev/null \
    | grep -c "RUNNING" || true)
  pg_down=$($KUBECTL get pods -n "$NAMESPACE" -l cnpg.io/podRole=instance \
    -o jsonpath='{range .items[*]}{.metadata.labels.status\.zeropod\.ctrox\.dev/postgres}{"\n"}{end}' 2>/dev/null \
    | grep -c "SCALED_DOWN" || true)
  pg_pending=$((INSTANCES - pg_total))

  if [ "$POOLER" = "1" ]; then
    pool_down=$($KUBECTL get pods -n "$NAMESPACE" -l cnpg.io/podRole=pooler \
      -o jsonpath='{range .items[*]}{.metadata.labels.status\.zeropod\.ctrox\.dev/pgbouncer}{"\n"}{end}' 2>/dev/null \
      | grep -c "SCALED_DOWN" || true)
    msg="  pg: ${pg_down}↓ ${pg_running}↑ ${pg_pending}… /${INSTANCES}  pooler: ${pool_down}↓/${INSTANCES}"
    [ "$msg" != "$last_msg" ] && info "$msg" && last_msg="$msg"
    [ "$pg_down" -ge "$INSTANCES" ] && [ "$pool_down" -ge "$INSTANCES" ] && break
  else
    msg="  pg: ${pg_down}↓ ${pg_running}↑ ${pg_pending}… /${INSTANCES}"
    [ "$msg" != "$last_msg" ] && info "$msg" && last_msg="$msg"
    [ "$pg_down" -ge "$INSTANCES" ] && break
  fi
  sleep 5
done

pg_down=$($KUBECTL get pods -n "$NAMESPACE" -l cnpg.io/podRole=instance \
  -o jsonpath='{range .items[*]}{.metadata.labels.status\.zeropod\.ctrox\.dev/postgres}{"\n"}{end}' 2>/dev/null \
  | grep -c "SCALED_DOWN" || true)
if [ "$pg_down" -lt "$INSTANCES" ]; then
  warn "Only ${pg_down}/${INSTANCES} checkpointed. Continuing with what we have."
  INSTANCES="$pg_down"
fi
ok "All checkpointed"

# ---------------------------------------------------------------------------
# 4. Build connection string for Go bench
# ---------------------------------------------------------------------------
info "Building connection map..."
CONNSTR_PAIRS=()
for i in $(seq -w 1 "$INSTANCES"); do
  name="${PREFIX}-${i}"
  pw=$($KUBECTL get secret "${name}-superuser" -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null) || continue

  if [ "$POOLER" = "1" ]; then
    svc_ip=$($KUBECTL get svc "${name}-pooler" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null) || continue
  else
    svc_ip=$($KUBECTL get svc "${name}-rw" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null) || continue
  fi
  CONNSTR_PAIRS+=("${name}=postgresql://postgres:${pw}@${svc_ip}:5432/postgres?sslmode=disable")
done

CONNSTRS=$(IFS=,; echo "${CONNSTR_PAIRS[*]}")
ACTUAL_COUNT=${#CONNSTR_PAIRS[@]}
ok "${ACTUAL_COUNT} instances ready"

# ---------------------------------------------------------------------------
# 5. Run Go bench binary
# ---------------------------------------------------------------------------
echo ""
info "=== Running bench: ${ACTUAL_COUNT} instances, ${ITERATIONS} cycles, offset=${OFFSET_MS}ms, pooler=${POOLER} ==="
echo ""

$KUBECTL exec "$BENCH_POD" -n "$NAMESPACE" -- /bench \
  -connstrs "$CONNSTRS" \
  -iterations "$ITERATIONS" \
  -offset-ms "$OFFSET_MS" \
  -timeout 30 \
  -wait-ready "$WAIT_READY"

# ---------------------------------------------------------------------------
# 6. Zeropod restore durations from manager logs
# ---------------------------------------------------------------------------
echo ""
info "=== Zeropod restore durations (from manager logs) ==="
$KUBECTL logs ds/zeropod-node -n zeropod-system --since=10m 2>/dev/null \
  | grep "status event" \
  | grep '"phase":"RUNNING"' \
  | grep "\"pod\":\"${PREFIX}-" \
  | tail -"$((ACTUAL_COUNT * ITERATIONS))" \
  | while read -r line; do
    pod=$(echo "$line" | grep -oP '"pod":"[^"]*"' | cut -d'"' -f4)
    duration=$(echo "$line" | grep -oP '"duration":"[^"]*"' | cut -d'"' -f4)
    printf "  %-30s %s\n" "$pod" "$duration"
  done
echo ""
