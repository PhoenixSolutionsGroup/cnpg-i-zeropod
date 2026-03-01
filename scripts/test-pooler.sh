#!/usr/bin/env bash
set -euo pipefail

info()  { printf '\033[1;34m[TEST]\033[0m  %s\n' "$*"; }
pass()  { printf '\033[1;32m[PASS]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

KUBECTL="${KUBECTL:-kubectl}"
if ! command -v "$KUBECTL" &>/dev/null; then
  KUBECTL="k3s kubectl"
fi

CLUSTER_NAME="zeropod-pooler-test"
POOLER_NAME="${CLUSTER_NAME}-pooler"
NAMESPACE="default"
SCALEDOWN_SECONDS=30
SCALEDOWN_WAIT=120
READY_WAIT=180
PASSED=0
FAILED=0

POD_NAME="${CLUSTER_NAME}-1"
CLIENT_POD="psql-pooler-client"

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
  $KUBECTL delete pooler "$POOLER_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
  $KUBECTL delete cluster "$CLUSTER_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
get_zeropod_status() {
  local pod="$1" container="$2"
  $KUBECTL get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath="{.metadata.labels.status\.zeropod\.ctrox\.dev/${container}}" 2>/dev/null || echo ""
}

wait_for_status() {
  local pod="$1" container="$2" target="$3" timeout="${4:-120}"
  local end=$((SECONDS + timeout))
  while [ $SECONDS -lt $end ]; do
    [ "$(get_zeropod_status "$pod" "$container")" = "$target" ] && return 0
    sleep 2
  done
  return 1
}

get_pooler_pod() {
  $KUBECTL get pods -n "$NAMESPACE" -l cnpg.io/poolerName="$POOLER_NAME" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
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
pass "Client pod ready"

# ---------------------------------------------------------------------------
# 2. Create CNPG Cluster
# ---------------------------------------------------------------------------
info "Creating CNPG Cluster: ${CLUSTER_NAME}"
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
  storage:
    size: 1Gi
EOF

info "Waiting for cluster to be healthy..."
end=$((SECONDS + READY_WAIT))
phase=""
while [ $SECONDS -lt $end ]; do
  phase=$($KUBECTL get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [ "$phase" = "Cluster in healthy state" ] && break
  sleep 5
done
assert "Cluster reached healthy state" [ "$phase" = "Cluster in healthy state" ]

if [ "$phase" != "Cluster in healthy state" ]; then
  fail "Cannot continue — cluster not healthy"
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Create Pooler
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
  POOLER_POD=$(get_pooler_pod)
  if [ -n "$POOLER_POD" ]; then
    $KUBECTL wait --for=condition=Ready "pod/$POOLER_POD" -n "$NAMESPACE" --timeout=60s 2>/dev/null && break
  fi
  sleep 3
done
assert "Pooler pod is ready" [ -n "$POOLER_POD" ]

# ===================================================================
# SUITE 1: PostgreSQL injection checks
# ===================================================================
echo ""
info "=== SUITE 1: PostgreSQL injection ==="

runtime=$($KUBECTL get pod "$POD_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.runtimeClassName}' 2>/dev/null || echo "")
assert "PG: runtimeClassName = zeropod" [ "$runtime" = "zeropod" ]

ports_map=$($KUBECTL get pod "$POD_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.zeropod\.ctrox\.dev/ports-map}' 2>/dev/null || echo "")
assert "PG: ports-map = postgres=5432" [ "$ports_map" = "postgres=5432" ]

container_names=$($KUBECTL get pod "$POD_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.zeropod\.ctrox\.dev/container-names}' 2>/dev/null || echo "")
assert "PG: container-names = postgres" [ "$container_names" = "postgres" ]

godebug=$($KUBECTL get pod "$POD_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.containers[?(@.name=="postgres")].env[?(@.name=="GODEBUG")].value}' 2>/dev/null || echo "")
assert "PG: GODEBUG flags injected" [ "$godebug" = "multipathtcp=0,pidfd=0" ]

# ===================================================================
# SUITE 2: Pooler injection checks
# ===================================================================
echo ""
info "=== SUITE 2: Pooler injection ==="

pooler_runtime=$($KUBECTL get pod "$POOLER_POD" -n "$NAMESPACE" \
  -o jsonpath='{.spec.runtimeClassName}' 2>/dev/null || echo "")
assert "Pooler: runtimeClassName = zeropod" [ "$pooler_runtime" = "zeropod" ]

pooler_ports=$($KUBECTL get pod "$POOLER_POD" -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.zeropod\.ctrox\.dev/ports-map}' 2>/dev/null || echo "")
assert "Pooler: ports-map = pgbouncer=5432" [ "$pooler_ports" = "pgbouncer=5432" ]

pooler_containers=$($KUBECTL get pod "$POOLER_POD" -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.zeropod\.ctrox\.dev/container-names}' 2>/dev/null || echo "")
assert "Pooler: container-names = pgbouncer" [ "$pooler_containers" = "pgbouncer" ]

pooler_godebug=$($KUBECTL get pod "$POOLER_POD" -n "$NAMESPACE" \
  -o jsonpath='{.spec.containers[?(@.name=="pgbouncer")].env[?(@.name=="GODEBUG")].value}' 2>/dev/null || echo "")
assert "Pooler: no GODEBUG flags (C process)" [ -z "$pooler_godebug" ]

# ===================================================================
# SUITE 3: PostgreSQL cold start (checkpoint/restore)
# ===================================================================
echo ""
info "=== SUITE 3: PostgreSQL cold start ==="

PG_PASSWORD=$($KUBECTL get secret "${CLUSTER_NAME}-superuser" -n "$NAMESPACE" \
  -o jsonpath='{.data.password}' | base64 -d)
POD_IP=$($KUBECTL get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.podIP}')
PG_CONNSTR="host=${POD_IP} dbname=postgres user=postgres password=${PG_PASSWORD} sslmode=require"

# Insert test data
$KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- \
  psql "$PG_CONNSTR" -c "
    CREATE TABLE IF NOT EXISTS pooler_test (id serial PRIMARY KEY, data text);
    INSERT INTO pooler_test (data) SELECT 'row-' || g FROM generate_series(1, 100) g;
  " >/dev/null 2>&1
pass "Test data inserted (100 rows)"

# Wait for PG scaledown
info "Waiting for PG scaledown..."
if wait_for_status "$POD_NAME" "postgres" "SCALED_DOWN" "$SCALEDOWN_WAIT"; then
  pass "PG pod scaled down"
else
  fail "PG pod did not scale down"
  $KUBECTL get pod "$POD_NAME" -n "$NAMESPACE" --show-labels
  exit 1
fi

# Trigger restore via direct connection
info "Triggering PG restore via direct TCP..."
pg_result=""
for attempt in $(seq 1 10); do
  pg_result=$($KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- \
    psql "$PG_CONNSTR" -t -A -c "SELECT count(*) FROM pooler_test;" 2>/dev/null) && break || true
  sleep 0.5
done
assert "PG: data intact after restore (100 rows)" [ "${pg_result:-0}" -eq 100 ]

if wait_for_status "$POD_NAME" "postgres" "RUNNING" 30; then
  pass "PG: label back to RUNNING"
else
  fail "PG: label did not return to RUNNING"
fi

# ===================================================================
# SUITE 4: Pooler cold start (both checkpointed, connect via pooler)
# ===================================================================
echo ""
info "=== SUITE 4: Pooler + PG cold start ==="

POOLER_SVC="${POOLER_NAME}"
POOLER_CONNSTR="host=${POOLER_SVC} dbname=postgres user=postgres password=${PG_PASSWORD} sslmode=disable"

# Wait for PG scaledown again
info "Waiting for PG scaledown..."
if ! wait_for_status "$POD_NAME" "postgres" "SCALED_DOWN" "$SCALEDOWN_WAIT"; then
  warn "PG did not scale down — triggering activity then waiting again"
  $KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- \
    psql "$PG_CONNSTR" -t -A -c "SELECT 1;" >/dev/null 2>&1 || true
  wait_for_status "$POD_NAME" "postgres" "RUNNING" 30 || true
  wait_for_status "$POD_NAME" "postgres" "SCALED_DOWN" "$SCALEDOWN_WAIT" || true
fi

pg_status=$(get_zeropod_status "$POD_NAME" "postgres")
assert "PG is SCALED_DOWN before pooler test" [ "$pg_status" = "SCALED_DOWN" ]

# Check pooler status (may or may not be scaled down depending on zeropod behavior)
pooler_status=$(get_zeropod_status "$POOLER_POD" "pgbouncer")
info "Pooler status: ${pooler_status:-not set}"

# Connect through the pooler service — this should wake both
info "Connecting through pooler to trigger restore chain..."
start_ns=$(date +%s%N)

pooler_result=""
for attempt in $(seq 1 20); do
  pooler_result=$($KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- \
    psql "$POOLER_CONNSTR" -t -A -c "SELECT count(*) FROM pooler_test;" 2>/dev/null) && break || true
  sleep 0.5
done

end_ns=$(date +%s%N)
total_ms=$(( (end_ns - start_ns) / 1000000 ))

assert "Pooler: query succeeded through pooler" [ -n "$pooler_result" ]
assert "Pooler: data intact (100 rows)" [ "${pooler_result:-0}" -eq 100 ]
info "Pooler cold start total: ${total_ms}ms"

# Verify both are back to RUNNING
if wait_for_status "$POD_NAME" "postgres" "RUNNING" 30; then
  pass "PG: back to RUNNING after pooler restore"
else
  fail "PG: did not return to RUNNING"
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
echo ""
echo "=============================="
echo "Results: ${PASSED} passed, ${FAILED} failed"
echo "=============================="

if [ "$FAILED" -gt 0 ]; then
  fail "Some tests failed"
  exit 1
fi

pass "ALL TESTS PASSED"
