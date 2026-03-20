#!/usr/bin/env bash
# Test: PG process crash recovery (instance manager restarts PG within the pod)
# This does NOT trigger CNPG failover — the instance manager handles it locally.
# For pod-level failover, see test-failover.sh
set -euo pipefail

info()  { printf '\033[1;34m[TEST]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[PASS]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; }

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

KUBECTL="${KUBECTL:-kubectl}"
if ! command -v "$KUBECTL" &>/dev/null; then
  KUBECTL="k3s kubectl"
fi

CLUSTER_NAME="${1:-failover-test}"
NAMESPACE="${2:-default}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
STORAGE_SIZE="${STORAGE_SIZE:-1Gi}"
CLIENT_POD="psql-failover-client"

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
ok "Client pod ready"

# ---------------------------------------------------------------------------
# 2. Create 3-instance cluster
# ---------------------------------------------------------------------------
info "Creating CNPG cluster: ${CLUSTER_NAME} (3 instances, scaledown: 30s)"
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
    cnpg.io/scale-to-zero-inactivity-seconds: "30"
spec:
  instances: 3
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
ok "Cluster healthy with 3 instances"

# ---------------------------------------------------------------------------
# 4. Identify primary and get connection info
# ---------------------------------------------------------------------------
PRIMARY=$($KUBECTL get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.currentPrimary}')
info "Current primary: $PRIMARY"

# List all pods
info "Instance pods:"
$KUBECTL get pods -n "$NAMESPACE" -l cnpg.io/cluster="$CLUSTER_NAME" \
  -o custom-columns='NAME:.metadata.name,ROLE:.metadata.labels.cnpg\.io/instanceRole,STATUS:.status.phase,READY:.status.conditions[?(@.type=="Ready")].status' 2>/dev/null

PRIMARY_IP=$($KUBECTL get pod "$PRIMARY" -n "$NAMESPACE" -o jsonpath='{.status.podIP}')
PG_PASSWORD=$($KUBECTL get secret "${CLUSTER_NAME}-superuser" -n "$NAMESPACE" \
  -o jsonpath='{.data.password}' | base64 -d)
RW_CONNSTR="host=${CLUSTER_NAME}-rw dbname=postgres user=postgres password=${PG_PASSWORD} sslmode=require"
PRIMARY_CONNSTR="host=${PRIMARY_IP} dbname=postgres user=postgres password=${PG_PASSWORD} sslmode=require"

# ---------------------------------------------------------------------------
# 5. Insert test data
# ---------------------------------------------------------------------------
info "Inserting test data on primary..."
$KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- psql "$PRIMARY_CONNSTR" -c "
  CREATE TABLE IF NOT EXISTS failover_test (id serial PRIMARY KEY, data text, ts timestamptz DEFAULT now());
  INSERT INTO failover_test (data) VALUES ('before-failover');
" >/dev/null
ok "Test data inserted"

# Verify via -rw service
info "Verifying data via -rw service..."
result=$($KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- psql "$RW_CONNSTR" -t -A -c \
  "SELECT data FROM failover_test WHERE data = 'before-failover';" 2>/dev/null)
if [ "$result" = "before-failover" ]; then
  ok "Data readable via -rw service"
else
  fail "Cannot read data via -rw service: $result"
  exit 1
fi

# ---------------------------------------------------------------------------
# 6. Kill PostgreSQL on primary
# ---------------------------------------------------------------------------
echo ""
info "============================================"
info "KILLING POSTGRES PROCESS ON PRIMARY: $PRIMARY"
info "============================================"
echo ""

# Get the PG postmaster PID and kill it
$KUBECTL exec "$PRIMARY" -n "$NAMESPACE" -- bash -c '
  PG_PID=$(head -1 /var/lib/postgresql/data/pgdata/postmaster.pid 2>/dev/null || echo "")
  if [ -n "$PG_PID" ]; then
    echo "Killing postmaster PID: $PG_PID"
    kill -9 $PG_PID
  else
    echo "Could not find postmaster PID, trying pkill"
    pkill -9 postgres || true
  fi
' 2>&1 || true

KILL_TIME=$SECONDS
info "PG killed at T+${KILL_TIME}s"

# ---------------------------------------------------------------------------
# 7. Watch for failover
# ---------------------------------------------------------------------------
info "Watching for failover (timeout: 120s)..."
echo ""

FAILOVER_DETECTED=false
NEW_PRIMARY=""
end=$((SECONDS + 120))
while [ $SECONDS -lt $end ]; do
  current=$($KUBECTL get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.currentPrimary}' 2>/dev/null || echo "")
  phase=$($KUBECTL get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  ready=$($KUBECTL get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "?")

  elapsed=$((SECONDS - KILL_TIME))
  printf "  T+%3ds | primary: %-25s | phase: %-40s | ready: %s/3\n" \
    "$elapsed" "$current" "$phase" "$ready"

  if [ "$current" != "$PRIMARY" ] && [ -n "$current" ]; then
    FAILOVER_DETECTED=true
    NEW_PRIMARY="$current"
    FAILOVER_TIME=$((SECONDS - KILL_TIME))
    echo ""
    ok "FAILOVER DETECTED after ${FAILOVER_TIME}s!"
    ok "New primary: $NEW_PRIMARY (was: $PRIMARY)"
    break
  fi
  sleep 3
done

if [ "$FAILOVER_DETECTED" = false ]; then
  echo ""
  fail "Failover NOT detected within 120s"
  info "Final cluster state:"
  $KUBECTL get cluster "$CLUSTER_NAME" -n "$NAMESPACE" -o yaml | grep -A20 "status:" || true
  exit 1
fi

# ---------------------------------------------------------------------------
# 8. Wait for cluster to stabilize
# ---------------------------------------------------------------------------
echo ""
info "Waiting for cluster to stabilize..."
end=$((SECONDS + 120))
while [ $SECONDS -lt $end ]; do
  phase=$($KUBECTL get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  ready=$($KUBECTL get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")
  [ "$phase" = "Cluster in healthy state" ] && [ "$ready" = "3" ] && break
  printf "  Phase: %s, Ready: %s/3\n" "$phase" "$ready"
  sleep 5
done

if [ "$phase" = "Cluster in healthy state" ] && [ "$ready" = "3" ]; then
  ok "Cluster re-stabilized with 3 healthy instances"
else
  warn "Cluster not fully healthy yet: phase=$phase, ready=$ready (may need more time)"
fi

# ---------------------------------------------------------------------------
# 9. Verify data integrity
# ---------------------------------------------------------------------------
echo ""
info "Verifying data integrity on new primary via -rw service..."

# Retry a few times as the service endpoint may need a moment to update
DATA_OK=false
for attempt in $(seq 1 10); do
  result=$($KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- psql "$RW_CONNSTR" -t -A -c \
    "SELECT data FROM failover_test WHERE data = 'before-failover';" 2>/dev/null || echo "")
  if [ "$result" = "before-failover" ]; then
    DATA_OK=true
    break
  fi
  sleep 2
done

if [ "$DATA_OK" = true ]; then
  ok "Data intact on new primary"
else
  fail "Data NOT found on new primary: $result"
fi

# Insert more data to verify writes work
info "Inserting data on new primary..."
INSERT_OK=false
for attempt in $(seq 1 10); do
  if $KUBECTL exec "$CLIENT_POD" -n "$NAMESPACE" -- psql "$RW_CONNSTR" -c \
    "INSERT INTO failover_test (data) VALUES ('after-failover');" >/dev/null 2>&1; then
    INSERT_OK=true
    break
  fi
  sleep 2
done

if [ "$INSERT_OK" = true ]; then
  ok "Writes work on new primary"
else
  fail "Cannot write to new primary"
fi

# ---------------------------------------------------------------------------
# 10. Final status
# ---------------------------------------------------------------------------
echo ""
info "Final instance status:"
$KUBECTL get pods -n "$NAMESPACE" -l cnpg.io/cluster="$CLUSTER_NAME" \
  -o custom-columns='NAME:.metadata.name,ROLE:.metadata.labels.cnpg\.io/instanceRole,STATUS:.status.phase,READY:.status.conditions[?(@.type=="Ready")].status' 2>/dev/null

echo ""
echo "======================================"
echo "  Failover Test Results"
echo "======================================"
echo ""
echo "  Primary killed:      $PRIMARY"
echo "  Failover detected:   ${FAILOVER_DETECTED}"
echo "  New primary:         ${NEW_PRIMARY:-N/A}"
echo "  Failover time:       ${FAILOVER_TIME:-N/A}s"
echo "  Data integrity:      ${DATA_OK}"
echo "  Writes on new primary: ${INSERT_OK}"
echo ""

if [ "$FAILOVER_DETECTED" = true ] && [ "$DATA_OK" = true ] && [ "$INSERT_OK" = true ]; then
  ok "ALL TESTS PASSED"
else
  fail "SOME TESTS FAILED"
  exit 1
fi
