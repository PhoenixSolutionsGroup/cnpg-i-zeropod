#!/usr/bin/env bash
# Test: Multi-replica support (1 primary + 2 replicas) with zeropod scale-to-zero
#
# Covers TODO investigation item 1:
#   - Deploy instances: 3 cluster with zeropod
#   - Verify all 3 pods get zeropod runtime
#   - Check if replicas scale down independently
#   - Check if primary scales down after replicas checkpoint
#   - Force restore of a replica, verify replication resumes
#   - Measure replication lag after replica restore
set -euo pipefail

info()  { printf '\033[1;34m[TEST]\033[0m %s\n' "$*"; }
pass()  { printf '\033[1;32m[PASS]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; }

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

KUBECTL="${KUBECTL:-kubectl}"
if ! command -v "$KUBECTL" &>/dev/null; then
  KUBECTL="k3s kubectl"
fi

CLUSTER_NAME="${1:-replica-test}"
NAMESPACE="${2:-default}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
STORAGE_SIZE="${STORAGE_SIZE:-10Gi}"
SCALEDOWN="${SCALEDOWN:-60}"
SCALEDOWN_WAIT=120
CLIENT_POD="psql-replica-client"
PASSED=0
FAILED=0

assert() {
  local desc="$1"
  shift
  if "$@"; then
    pass "$desc"
    PASSED=$((PASSED + 1))
  else
    fail "$desc"
    FAILED=$((FAILED + 1))
  fi
}

cleanup() {
  info "Cleaning up..."
  $KUBECTL delete pod "$CLIENT_POD" -n "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
  $KUBECTL delete cluster "$CLUSTER_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Create client pod
# ---------------------------------------------------------------------------
info "Creating psql client pod..."
$KUBECTL delete pod "$CLIENT_POD" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
sleep 1
$KUBECTL run "$CLIENT_POD" --image=postgres:17 --restart=Never -n "$NAMESPACE" \
  --command -- sleep 3600
$KUBECTL wait --for=condition=Ready "pod/$CLIENT_POD" -n "$NAMESPACE" --timeout=60s
pass "Client pod ready"

# ---------------------------------------------------------------------------
# 2. Create 3-instance cluster
# ---------------------------------------------------------------------------
info "Creating CNPG cluster: ${CLUSTER_NAME} (3 instances, scaledown: ${SCALEDOWN}s)"
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
    cnpg.io/scale-to-zero-inactivity-seconds: "${SCALEDOWN}"
spec:
  instances: 3
  enableSuperuserAccess: true
  plugins:
    - name: cnpg-i-zeropod.io
  postgresql:
    parameters:
      shared_memory_type: mmap
      dynamic_shared_memory_type: posix
      shared_buffers: "64MB"
  storage:
    size: ${STORAGE_SIZE}
$([ -n "$STORAGE_CLASS" ] && echo "    storageClass: ${STORAGE_CLASS}")
EOF

# ---------------------------------------------------------------------------
# 3. Wait for healthy
# ---------------------------------------------------------------------------
info "Waiting for cluster to be healthy (3 instances)..."
end=$((SECONDS + 300))
while [ $SECONDS -lt $end ]; do
  phase=$($KUBECTL get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  instances=$($KUBECTL get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")
  [ "$phase" = "Cluster in healthy state" ] && [ "$instances" = "3" ] && break
  printf "  Phase: %s, Ready: %s/3\n" "$phase" "$instances"
  sleep 5
done
if [ "$phase" != "Cluster in healthy state" ] || [ "$instances" != "3" ]; then
  fail "Cluster not healthy: phase=$phase, ready=$instances"
  exit 1
fi
pass "Cluster healthy with 3 instances"

# ---------------------------------------------------------------------------
# 4. Verify zeropod injection on all pods
# ---------------------------------------------------------------------------
info "Checking zeropod injection on all 3 pods..."
for i in 1 2 3; do
  pod="${CLUSTER_NAME}-${i}"
  runtime=$($KUBECTL get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath='{.spec.runtimeClassName}' 2>/dev/null || echo "")
  ports=$($KUBECTL get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.zeropod\.ctrox\.dev/ports-map}' 2>/dev/null || echo "")
  assert "$pod: runtimeClassName=zeropod" [ "$runtime" = "zeropod" ]
  assert "$pod: ports-map=postgres=5432" [ "$ports" = "postgres=5432" ]
done

# ---------------------------------------------------------------------------
# 5. Get connection info and insert test data
# ---------------------------------------------------------------------------
PRIMARY=$($KUBECTL get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.currentPrimary}')
info "Current primary: $PRIMARY"

$KUBECTL get pods -n "$NAMESPACE" -l cnpg.io/cluster="$CLUSTER_NAME" \
  -o custom-columns='NAME:.metadata.name,ROLE:.metadata.labels.cnpg\.io/instanceRole,NODE:.spec.nodeName' 2>/dev/null

PRIMARY_IP=$($KUBECTL get pod "$PRIMARY" -n "$NAMESPACE" -o jsonpath='{.status.podIP}')
PG_PASSWORD=$($KUBECTL get secret "${CLUSTER_NAME}-superuser" -n "$NAMESPACE" \
  -o jsonpath='{.data.password}' | base64 -d)
PRIMARY_CONNSTR="host=${PRIMARY_IP} dbname=postgres user=postgres password=${PG_PASSWORD} sslmode=require"

info "Inserting test data..."
$KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- psql "$PRIMARY_CONNSTR" -c "
  CREATE TABLE IF NOT EXISTS replica_test (id serial PRIMARY KEY, data text, ts timestamptz DEFAULT now());
  INSERT INTO replica_test (data) SELECT 'row-' || g FROM generate_series(1, 100) g;
" >/dev/null
pass "100 rows inserted"

# Verify replication is streaming before we start
info "Checking replication is active..."
REP_COUNT=$($KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- psql "$PRIMARY_CONNSTR" -t -A -c \
  "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming';")
assert "2 streaming replicas" [ "$REP_COUNT" = "2" ]

# ---------------------------------------------------------------------------
# 6. Wait for replicas to scale down
# ---------------------------------------------------------------------------
info "Waiting for replicas to scale down (scaledown=${SCALEDOWN}s, timeout=${SCALEDOWN_WAIT}s)..."
end=$((SECONDS + SCALEDOWN_WAIT))
replicas_down=0
while [ $SECONDS -lt $end ]; do
  replicas_down=0
  for i in 1 2 3; do
    pod="${CLUSTER_NAME}-${i}"
    role=$($KUBECTL get pod "$pod" -n "$NAMESPACE" \
      -o jsonpath='{.metadata.labels.cnpg\.io/instanceRole}' 2>/dev/null || echo "")
    zstatus=$($KUBECTL get pod "$pod" -n "$NAMESPACE" \
      -o jsonpath='{.metadata.labels.status\.zeropod\.ctrox\.dev/postgres}' 2>/dev/null || echo "")
    if [ "$role" = "replica" ] && [ "$zstatus" = "SCALED_DOWN" ]; then
      replicas_down=$((replicas_down + 1))
    fi
  done
  [ "$replicas_down" -ge 2 ] && break
  printf "  Replicas scaled down: %s/2\n" "$replicas_down"
  sleep 5
done
assert "Both replicas scaled down" [ "$replicas_down" -ge 2 ]

# Check primary is still running (replication connections may keep it alive briefly)
PRIMARY_STATUS=$($KUBECTL get pod "$PRIMARY" -n "$NAMESPACE" \
  -o jsonpath='{.metadata.labels.status\.zeropod\.ctrox\.dev/postgres}' 2>/dev/null || echo "")
info "Primary status after replicas scaled down: $PRIMARY_STATUS"

# ---------------------------------------------------------------------------
# 7. Check if primary scales down after replicas checkpoint
# ---------------------------------------------------------------------------
info "Waiting for primary to scale down (timeout=${SCALEDOWN_WAIT}s)..."
end=$((SECONDS + SCALEDOWN_WAIT))
primary_down=false
while [ $SECONDS -lt $end ]; do
  pstatus=$($KUBECTL get pod "$PRIMARY" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.status\.zeropod\.ctrox\.dev/postgres}' 2>/dev/null || echo "")
  if [ "$pstatus" = "SCALED_DOWN" ]; then
    primary_down=true
    break
  fi
  printf "  Primary: %s\n" "$pstatus"
  sleep 5
done
assert "Primary scaled down after replicas" [ "$primary_down" = "true" ]

info "All 3 pods are SCALED_DOWN"
for i in 1 2 3; do
  pod="${CLUSTER_NAME}-${i}"
  zstatus=$($KUBECTL get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.status\.zeropod\.ctrox\.dev/postgres}' 2>/dev/null || echo "")
  role=$($KUBECTL get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.cnpg\.io/instanceRole}' 2>/dev/null || echo "")
  echo "  $pod ($role): $zstatus"
done

# ---------------------------------------------------------------------------
# 8. Patch -rw service for publishNotReadyAddresses and wake primary
# ---------------------------------------------------------------------------
info "Patching -rw service with publishNotReadyAddresses..."
$KUBECTL patch svc "${CLUSTER_NAME}-rw" -n "$NAMESPACE" \
  --type=merge -p '{"spec":{"publishNotReadyAddresses":true}}'

# Also patch -ro for later replica wake test
$KUBECTL patch svc "${CLUSTER_NAME}-ro" -n "$NAMESPACE" \
  --type=merge -p '{"spec":{"publishNotReadyAddresses":true}}'

sleep 2

info "Waking primary via -rw service (SELECT)..."
RW_CONNSTR="host=${CLUSTER_NAME}-rw dbname=postgres user=postgres password=${PG_PASSWORD} sslmode=require"

PRIMARY_WOKE=false
for attempt in $(seq 1 5); do
  result=$($KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- psql "$RW_CONNSTR" -t -A -c \
    "SELECT 'alive';" 2>/dev/null || echo "")
  if [ "$result" = "alive" ]; then
    PRIMARY_WOKE=true
    break
  fi
  info "  Attempt $attempt: primary restoring..."
  sleep 3
done
assert "Primary woke via -rw service" [ "$PRIMARY_WOKE" = "true" ]

# Confirm replicas are still scaled down
sleep 2
REPLICA_STILL_DOWN=0
for i in 1 2 3; do
  pod="${CLUSTER_NAME}-${i}"
  role=$($KUBECTL get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.cnpg\.io/instanceRole}' 2>/dev/null || echo "")
  zstatus=$($KUBECTL get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.status\.zeropod\.ctrox\.dev/postgres}' 2>/dev/null || echo "")
  if [ "$role" = "replica" ] && [ "$zstatus" = "SCALED_DOWN" ]; then
    REPLICA_STILL_DOWN=$((REPLICA_STILL_DOWN + 1))
  fi
done
assert "Replicas still scaled down after primary wake" [ "$REPLICA_STILL_DOWN" -ge 2 ]

# ---------------------------------------------------------------------------
# 9. Insert data while replicas are checkpointed
# ---------------------------------------------------------------------------
info "Inserting more data while replicas are checkpointed..."
$KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- psql "$RW_CONNSTR" -c \
  "INSERT INTO replica_test (data) SELECT 'after-checkpoint-' || g FROM generate_series(1, 50) g;" >/dev/null
pass "50 more rows inserted (replicas will need to catch up)"

TOTAL_ON_PRIMARY=$($KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- psql "$RW_CONNSTR" -t -A -c \
  "SELECT count(*) FROM replica_test;")
info "Total rows on primary: $TOTAL_ON_PRIMARY"

# ---------------------------------------------------------------------------
# 10. Wake a replica via -ro and verify replication catches up
# ---------------------------------------------------------------------------
info "Waking replica via -ro service..."
RO_CONNSTR="host=${CLUSTER_NAME}-ro dbname=postgres user=postgres password=${PG_PASSWORD} sslmode=require"

REPLICA_WOKE=false
REPLICA_COUNT=""
for attempt in $(seq 1 10); do
  result=$($KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- psql "$RO_CONNSTR" -t -A -c \
    "SELECT count(*) FROM replica_test;" 2>/dev/null || echo "")
  if [ -n "$result" ] && [ "$result" -gt 0 ] 2>/dev/null; then
    REPLICA_WOKE=true
    REPLICA_COUNT="$result"
    break
  fi
  info "  Attempt $attempt: replica restoring..."
  sleep 3
done
assert "Replica woke via -ro service" [ "$REPLICA_WOKE" = "true" ]

# ---------------------------------------------------------------------------
# 11. Measure replication lag
# ---------------------------------------------------------------------------
if [ "$REPLICA_WOKE" = "true" ]; then
  # Replica may need a moment to reconnect walreceiver and stream missed WAL
  if [ "$REPLICA_COUNT" != "$TOTAL_ON_PRIMARY" ]; then
    info "Replica has $REPLICA_COUNT rows (primary: $TOTAL_ON_PRIMARY), waiting for catch-up..."
    for attempt in $(seq 1 10); do
      sleep 1
      REPLICA_COUNT=$($KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- psql "$RO_CONNSTR" -t -A -c \
        "SELECT count(*) FROM replica_test;" 2>/dev/null || echo "0")
      [ "$REPLICA_COUNT" = "$TOTAL_ON_PRIMARY" ] && break
    done
  fi
  info "Replica row count: $REPLICA_COUNT (primary: $TOTAL_ON_PRIMARY)"
  assert "Replica caught up on missed WAL" [ "$REPLICA_COUNT" = "$TOTAL_ON_PRIMARY" ]

  # Check replication status on primary
  info "Checking replication status..."
  $KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- psql "$RW_CONNSTR" -c \
    "SELECT application_name, state, sent_lsn, write_lsn, flush_lsn, replay_lsn,
            pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replay_lag_bytes
     FROM pg_stat_replication;" 2>/dev/null

  REPLAY_LAG=$($KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- psql "$RO_CONNSTR" -t -A -c \
    "SELECT COALESCE(EXTRACT(EPOCH FROM replay_lag)::text, '0') FROM pg_stat_wal_receiver;" 2>/dev/null || echo "unknown")
  info "Replica replay_lag: ${REPLAY_LAG}s"
fi

# ---------------------------------------------------------------------------
# 12. Write-then-read: mimic real user (write via -rw, read via -ro)
# ---------------------------------------------------------------------------
echo ""
info "=== Write-then-read consistency test ==="
info "Simulating real user: write via -rw, immediately read via -ro"

# Write-then-read inside the client pod to avoid kubectl overhead per iteration.
# For each row: write to -rw, then poll -ro every 10ms until visible, measure latency.
$KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- bash -c "
export PGPASSWORD='${PG_PASSWORD}'
RW='host=${CLUSTER_NAME}-rw dbname=postgres user=postgres sslmode=require'
RO='host=${CLUSTER_NAME}-ro dbname=postgres user=postgres sslmode=require'
TOTAL=20
CONSISTENT=0
TOTAL_MS=0

for i in \$(seq 1 \$TOTAL); do
  # Write one row
  psql \"\$RW\" -t -A -c \"INSERT INTO replica_test (data) VALUES ('live-write-\$i');\" >/dev/null 2>&1

  # Poll replica until visible
  START_S=\$SECONDS
  START_NS=\$(date +%s%N 2>/dev/null || echo 0)
  TRIES=0
  while true; do
    TRIES=\$((TRIES + 1))
    FOUND=\$(psql \"\$RO\" -t -A -c \"SELECT 1 FROM replica_test WHERE data = 'live-write-\$i' LIMIT 1;\" 2>/dev/null)
    if [ \"\$FOUND\" = \"1\" ]; then
      break
    fi
    # timeout after 5s
    if [ \$((SECONDS - START_S)) -ge 5 ]; then
      echo \"  row \$i: TIMEOUT (not visible after 5s)\"
      break
    fi
    sleep 0.01
  done

  END_NS=\$(date +%s%N 2>/dev/null || echo 0)
  if [ \"\$START_NS\" != \"0\" ] && [ \"\$END_NS\" != \"0\" ]; then
    LAG_MS=\$(( (END_NS - START_NS) / 1000000 ))
  else
    LAG_MS=\$((SECONDS - START_S))000
  fi

  if [ \"\$FOUND\" = \"1\" ]; then
    echo \"  row \$i: visible in \${LAG_MS}ms (\$TRIES tries)\"
    TOTAL_MS=\$((TOTAL_MS + LAG_MS))
    if [ \$LAG_MS -lt 500 ]; then
      CONSISTENT=\$((CONSISTENT + 1))
    fi
  fi
done

AVG_MS=\$((TOTAL_MS / TOTAL))
echo \"\"
echo \"RESULTS: \$CONSISTENT/\$TOTAL within 500ms, avg=\${AVG_MS}ms\"
echo \"CONSISTENT_COUNT=\$CONSISTENT\"
echo \"AVG_LATENCY_MS=\$AVG_MS\"
" 2>/dev/null | tee /tmp/replica-consistency.txt

CONSISTENT=$(grep "CONSISTENT_COUNT=" /tmp/replica-consistency.txt | cut -d= -f2)
AVG_LAT=$(grep "AVG_LATENCY_MS=" /tmp/replica-consistency.txt | cut -d= -f2)
info "Consistent within 500ms: ${CONSISTENT:-0}/20, avg latency: ${AVG_LAT:-?}ms"
assert "At least 14/20 reads consistent within 500ms" [ "${CONSISTENT:-0}" -ge 14 ]

# Final count check
FINAL_PRIMARY=$($KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- psql "$RW_CONNSTR" -t -A -c \
  "SELECT count(*) FROM replica_test;")
FINAL_REPLICA=$($KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- psql "$RO_CONNSTR" -t -A -c \
  "SELECT count(*) FROM replica_test;")
info "Final row counts — primary: $FINAL_PRIMARY, replica: $FINAL_REPLICA"
assert "Final row counts match" [ "$FINAL_PRIMARY" = "$FINAL_REPLICA" ]

# ---------------------------------------------------------------------------
# 13. Verify cluster re-stabilizes
# ---------------------------------------------------------------------------
info "Waiting for cluster to re-stabilize..."
end=$((SECONDS + 120))
while [ $SECONDS -lt $end ]; do
  phase=$($KUBECTL get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  ready=$($KUBECTL get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")
  # At least primary + 1 replica should be ready
  [ "$ready" -ge 2 ] 2>/dev/null && break
  printf "  Phase: %s, Ready: %s/3\n" "$phase" "$ready"
  sleep 5
done
info "Final ready instances: $ready/3"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
echo ""
info "Final pod status:"
for i in 1 2 3; do
  pod="${CLUSTER_NAME}-${i}"
  role=$($KUBECTL get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.cnpg\.io/instanceRole}' 2>/dev/null || echo "")
  zstatus=$($KUBECTL get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.status\.zeropod\.ctrox\.dev/postgres}' 2>/dev/null || echo "")
  ready=$($KUBECTL get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  echo "  $pod ($role): zeropod=$zstatus ready=$ready"
done

echo ""
echo "======================================"
echo "  Multi-Replica Test Results"
echo "======================================"
echo "  ${PASSED} passed, ${FAILED} failed"
echo "======================================"
echo ""

if [ "$FAILED" -gt 0 ]; then
  fail "SOME TESTS FAILED"
  exit 1
fi

pass "ALL TESTS PASSED"
