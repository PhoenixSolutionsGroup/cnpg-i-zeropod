#!/usr/bin/env bash
set -euo pipefail

info()  { printf '\033[1;34m[BENCH]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[BENCH]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[BENCH]\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31m[BENCH]\033[0m %s\n' "$*"; }

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

KUBECTL="${KUBECTL:-kubectl}"
if ! command -v "$KUBECTL" &>/dev/null; then
  KUBECTL="k3s kubectl"
fi

CLUSTER_NAME="${1:-zeropod-bench}"
NAMESPACE="${2:-default}"
ITERATIONS="${3:-5}"
POD_NAME="${CLUSTER_NAME}-1"
POOLER_NAME="${CLUSTER_NAME}-pooler"
CLIENT_POD="psql-bench-client"
SCALEDOWN_SECONDS=15
STORAGE_SIZE="${STORAGE_SIZE:-1Gi}"
STORAGE_CLASS="${STORAGE_CLASS:-}"

cleanup() {
  info "Cleaning up..."
  $KUBECTL delete pod "$CLIENT_POD" -n "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
  $KUBECTL delete pooler "$POOLER_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
  $KUBECTL delete cluster "$CLUSTER_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: run psql from the persistent client pod
# ---------------------------------------------------------------------------
run_psql() {
  local connstr="$1"; shift
  $KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- psql "$connstr" "$@"
}

# Helper: time a psql query from the client pod (returns ms)
time_psql() {
  local connstr="$1"; shift
  local output
  output=$($KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- \
    bash -c "start=\$(date +%s%N); psql '$connstr' $* 2>&1; end=\$(date +%s%N); echo \"__TIME_NS__\$(( end - start ))\"" 2>&1)
  local time_ns
  time_ns=$(echo "$output" | grep '__TIME_NS__' | sed 's/__TIME_NS__//')
  local time_ms=$(( time_ns / 1000000 ))
  # Check if query succeeded
  if echo "$output" | grep -q "starting up\|connection refused\|could not connect"; then
    echo "-1"  # Failed
  else
    echo "$time_ms"
  fi
}

# Helper: time a psql query with retries (for cold start — first attempt may fail)
time_psql_with_retry() {
  local connstr="$1"; shift
  $KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- \
    bash -c '
      connstr="'"$connstr"'"
      start=$(date +%s%N)
      max_attempts=20
      for i in $(seq 1 $max_attempts); do
        result=$(psql "$connstr" -t -A -c "SELECT 1;" 2>&1)
        if echo "$result" | grep -q "^1$"; then
          end=$(date +%s%N)
          echo $(( (end - start) / 1000000 ))
          exit 0
        fi
        sleep 0.05
      done
      echo "-1"
    ' 2>/dev/null
}

get_zeropod_status() {
  $KUBECTL get pod "$POD_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.status\.zeropod\.ctrox\.dev/postgres}' 2>/dev/null || echo ""
}

wait_for_status() {
  local target="$1" timeout="${2:-120}"
  local end=$((SECONDS + timeout))
  while [ $SECONDS -lt $end ]; do
    [ "$(get_zeropod_status)" = "$target" ] && return 0
    sleep 1
  done
  return 1
}

# ---------------------------------------------------------------------------
# 1. Create persistent psql client pod
# ---------------------------------------------------------------------------
info "Creating persistent psql client pod..."
$KUBECTL delete pod "$CLIENT_POD" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
sleep 1
$KUBECTL run "$CLIENT_POD" --image=postgres:17 --restart=Never -n "$NAMESPACE" \
  --command -- sleep 3600
$KUBECTL wait --for=condition=Ready "pod/$CLIENT_POD" -n "$NAMESPACE" --timeout=60s
ok "Client pod ready"

# ---------------------------------------------------------------------------
# 2. Create bench cluster
# ---------------------------------------------------------------------------
info "Creating CNPG cluster: ${CLUSTER_NAME} (scaledown: ${SCALEDOWN_SECONDS}s)"
$KUBECTL delete cluster "$CLUSTER_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true 2>/dev/null || true
sleep 3

$KUBECTL apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${NAMESPACE}
  annotations:
    cnpg.io/scale-to-zero-enabled: "true"
    cnpg.io/scale-to-zero-inactivity-seconds: "${SCALEDOWN_SECONDS}"
spec:
  instances: 1
  enableSuperuserAccess: true
  plugins:
    - name: cnpg-i-zeropod.io
  postgresql:
    parameters:
      shared_memory_type: mmap
  storage:
    size: ${STORAGE_SIZE}
$([ -n "$STORAGE_CLASS" ] && echo "    storageClass: ${STORAGE_CLASS}")
EOF

# ---------------------------------------------------------------------------
# 3. Wait for healthy
# ---------------------------------------------------------------------------
info "Waiting for cluster to be healthy..."
end=$((SECONDS + 180))
while [ $SECONDS -lt $end ]; do
  phase=$($KUBECTL get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [ "$phase" = "Cluster in healthy state" ] && break
  sleep 5
done
[ "$phase" != "Cluster in healthy state" ] && { fail "Cluster not healthy: $phase"; exit 1; }
ok "Cluster healthy"

# ---------------------------------------------------------------------------
# 3b. Create Pooler
# ---------------------------------------------------------------------------
info "Creating CNPG Pooler: ${POOLER_NAME}"
$KUBECTL apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: ${POOLER_NAME}
  namespace: ${NAMESPACE}
spec:
  cluster:
    name: ${CLUSTER_NAME}
  instances: 1
  type: rw
  pgbouncer:
    poolMode: session
    parameters:
      max_client_conn: "100"
      default_pool_size: "10"
EOF

info "Waiting for pooler pod to be ready..."
end=$((SECONDS + 120))
POOLER_POD=""
while [ $SECONDS -lt $end ]; do
  POOLER_POD=$($KUBECTL get pods -n "$NAMESPACE" -l cnpg.io/poolerName="$POOLER_NAME" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$POOLER_POD" ]; then
    $KUBECTL wait --for=condition=Ready "pod/$POOLER_POD" -n "$NAMESPACE" --timeout=60s 2>/dev/null && break
  fi
  sleep 3
done
[ -n "$POOLER_POD" ] && ok "Pooler pod ready: $POOLER_POD" || { fail "Pooler pod not ready"; exit 1; }

# ---------------------------------------------------------------------------
# 4. Get connection details
# ---------------------------------------------------------------------------
POD_IP=$($KUBECTL get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.podIP}')
PG_PASSWORD=$($KUBECTL get secret "${CLUSTER_NAME}-superuser" -n "$NAMESPACE" \
  -o jsonpath='{.data.password}' | base64 -d)
CONNSTR="host=${POD_IP} dbname=postgres user=postgres password=${PG_PASSWORD} sslmode=require"
POOLER_CONNSTR="host=${POOLER_NAME} dbname=postgres user=postgres password=${PG_PASSWORD} sslmode=disable"

# Insert test data
run_psql "$CONNSTR" -c "
  CREATE TABLE IF NOT EXISTS bench_data (id serial PRIMARY KEY, data text);
  INSERT INTO bench_data (data) SELECT 'row-' || g FROM generate_series(1, 100) g;
" >/dev/null
ok "Test data inserted (100 rows)"

# ---------------------------------------------------------------------------
# 5. Warm benchmark
# ---------------------------------------------------------------------------
info ""
info "=== WARM QUERIES (PG running) ==="
warm_times=()
for i in $(seq 1 "$ITERATIONS"); do
  ms=$(time_psql_with_retry "$CONNSTR")
  if [ "$ms" -ge 0 ]; then
    warm_times+=("$ms")
    printf "  Run %d: %4d ms\n" "$i" "$ms"
  else
    warn "  Run $i: FAILED"
  fi
done

# ---------------------------------------------------------------------------
# 6. Cold benchmark
# ---------------------------------------------------------------------------
info ""
info "=== COLD QUERIES (from SCALED_DOWN) ==="
cold_times=()

for i in $(seq 1 "$ITERATIONS"); do
  # Ensure we're running first (query to trigger restore if needed)
  run_psql "$CONNSTR" -t -A -c "SELECT 1;" >/dev/null 2>&1 || true
  wait_for_status "RUNNING" 30 || true

  # Wait for scale-down
  info "  Waiting for scaledown..."
  if ! wait_for_status "SCALED_DOWN" 120; then
    warn "  Run $i: pod did not scale down, skipping"
    continue
  fi

  # Measure cold start (time until first successful query)
  ms=$(time_psql_with_retry "$CONNSTR")
  if [ "$ms" -ge 0 ]; then
    cold_times+=("$ms")
    printf "  Run %d: %4d ms\n" "$i" "$ms"
  else
    warn "  Run $i: FAILED (query never succeeded)"
  fi
done

# ---------------------------------------------------------------------------
# 7. Pooler + PG cold benchmark
# ---------------------------------------------------------------------------
info ""
info "=== POOLER + PG COLD QUERIES (from SCALED_DOWN, via PgBouncer) ==="
pooler_cold_times=()

for i in $(seq 1 "$ITERATIONS"); do
  # Ensure PG is running first
  run_psql "$CONNSTR" -t -A -c "SELECT 1;" >/dev/null 2>&1 || true
  wait_for_status "RUNNING" 30 || true

  # Wait for PG scale-down
  info "  Waiting for PG scaledown..."
  if ! wait_for_status "SCALED_DOWN" 120; then
    warn "  Run $i: PG did not scale down, skipping"
    continue
  fi

  # Measure cold start through the pooler (PgBouncer → PG restore chain)
  ms=$(time_psql_with_retry "$POOLER_CONNSTR")
  if [ "$ms" -ge 0 ]; then
    pooler_cold_times+=("$ms")
    printf "  Run %d: %4d ms\n" "$i" "$ms"
  else
    warn "  Run $i: FAILED (query never succeeded)"
  fi
done

# ---------------------------------------------------------------------------
# 8. Zeropod restore durations from logs
# ---------------------------------------------------------------------------
info ""
info "=== ZEROPOD RESTORE DURATIONS (from manager logs) ==="
$KUBECTL logs ds/zeropod-node -n zeropod-system --since=10m 2>/dev/null \
  | grep "status event" \
  | grep "\"pod\":\"${POD_NAME}\"" \
  | grep "RUNNING" \
  | tail -"$ITERATIONS" \
  | while read -r line; do
    duration=$(echo "$line" | grep -oP '"duration":"[^"]*"' | cut -d'"' -f4)
    printf "  %s\n" "$duration"
  done

# ---------------------------------------------------------------------------
# 9. Summary
# ---------------------------------------------------------------------------
print_stats() {
  local label="$1"; shift
  local -a vals=("$@")
  if [ ${#vals[@]} -eq 0 ]; then
    echo "  $label: no data"
    return
  fi
  local min=${vals[0]} max=${vals[0]} sum=0
  for t in "${vals[@]}"; do
    sum=$((sum + t))
    [ "$t" -lt "$min" ] && min=$t
    [ "$t" -gt "$max" ] && max=$t
  done
  local avg=$((sum / ${#vals[@]}))
  printf "\n  %s (%d samples):\n" "$label" "${#vals[@]}"
  printf "    Min:  %4d ms\n" "$min"
  printf "    Max:  %4d ms\n" "$max"
  printf "    Avg:  %4d ms\n" "$avg"
}

echo ""
echo "======================================"
echo "  Benchmark Results"
echo "======================================"
print_stats "Warm (PG running)" "${warm_times[@]}"
print_stats "Cold: PG direct (from SCALED_DOWN)" "${cold_times[@]}"
print_stats "Cold: Pooler + PG (via PgBouncer)" "${pooler_cold_times[@]}"
echo ""
