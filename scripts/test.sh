#!/usr/bin/env bash
set -euo pipefail

info()  { printf '\033[1;34m[TEST]\033[0m  %s\n' "$*"; }
pass()  { printf '\033[1;32m[PASS]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*"; }

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

KUBECTL="${KUBECTL:-kubectl}"
if ! command -v "$KUBECTL" &>/dev/null; then
  KUBECTL="k3s kubectl"
fi

CLUSTER_NAME="zeropod-test"
NAMESPACE="default"
SCALEDOWN_WAIT=180
READY_WAIT=180
ROW_COUNT=1000
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
  info "Cleaning up cluster ${CLUSTER_NAME}..."
  $KUBECTL delete cluster "$CLUSTER_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
}
trap cleanup EXIT

POD_NAME="${CLUSTER_NAME}-1"

# ---------------------------------------------------------------------------
# 1. Create CNPG Cluster
# ---------------------------------------------------------------------------
info "Creating CNPG Cluster: ${CLUSTER_NAME}"
$KUBECTL delete cluster "$CLUSTER_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true 2>/dev/null || true
sleep 5

$KUBECTL apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${NAMESPACE}
  annotations:
    cnpg.io/scale-to-zero-enabled: "true"
    cnpg.io/scale-to-zero-inactivity-seconds: "60"
spec:
  instances: 1
  enableSuperuserAccess: true
  plugins:
    - name: cnpg-i-zeropod.io
  postgresql:
    parameters:
      shared_memory_type: mmap
      dynamic_shared_memory_type: posix
      shared_buffers: "64MB"
  resources:
    requests:
      memory: "256Mi"
      cpu: "100m"
    limits:
      memory: "512Mi"
      cpu: "1"
  storage:
    size: 1Gi
EOF

# ---------------------------------------------------------------------------
# 2. Wait for cluster healthy
# ---------------------------------------------------------------------------
info "Waiting for cluster to be healthy (up to ${READY_WAIT}s)..."
end=$((SECONDS + READY_WAIT))
phase=""
while [ $SECONDS -lt $end ]; do
  phase=$($KUBECTL get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "$phase" = "Cluster in healthy state" ]; then
    break
  fi
  sleep 5
done
assert "Cluster reached healthy state" [ "$phase" = "Cluster in healthy state" ]

if [ "$phase" != "Cluster in healthy state" ]; then
  info "Cluster phase: ${phase}"
  info "Pod status:"
  $KUBECTL get pods -n "$NAMESPACE" -l cnpg.io/cluster="$CLUSTER_NAME" 2>/dev/null || true
  fail "Cannot continue — cluster not healthy"
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Verify zeropod injection
# ---------------------------------------------------------------------------
info "Checking zeropod runtime class injection..."
runtime=$($KUBECTL get pod "$POD_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.runtimeClassName}' 2>/dev/null || echo "")
assert "runtimeClassName = zeropod" [ "$runtime" = "zeropod" ]

ports_map=$($KUBECTL get pod "$POD_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.zeropod\.ctrox\.dev/ports-map}' 2>/dev/null || echo "")
assert "zeropod ports-map annotation present" [ "$ports_map" = "postgres=5432" ]

container_names=$($KUBECTL get pod "$POD_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.zeropod\.ctrox\.dev/container-names}' 2>/dev/null || echo "")
assert "zeropod container-names annotation present" [ "$container_names" = "postgres" ]

scaledown=$($KUBECTL get pod "$POD_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.zeropod\.ctrox\.dev/scaledown-duration}' 2>/dev/null || echo "")
assert "zeropod scaledown-duration annotation present" [ "$scaledown" = "60s" ]

# ---------------------------------------------------------------------------
# 4. Insert test data
# ---------------------------------------------------------------------------
info "Inserting ${ROW_COUNT} test rows..."
$KUBECTL exec -i "$POD_NAME" -n "$NAMESPACE" -c postgres -- \
  psql -U postgres -c "
    CREATE TABLE IF NOT EXISTS zeropod_test (id serial PRIMARY KEY, data text);
    INSERT INTO zeropod_test (data) SELECT 'row-' || g FROM generate_series(1, ${ROW_COUNT}) g;
  " >/dev/null

count=$($KUBECTL exec -i "$POD_NAME" -n "$NAMESPACE" -c postgres -- \
  psql -U postgres -t -A -c "SELECT count(*) FROM zeropod_test;")
assert "Inserted ${ROW_COUNT} rows" [ "$count" -eq "$ROW_COUNT" ]

# ---------------------------------------------------------------------------
# 5. Wait for scaledown
# ---------------------------------------------------------------------------
info "Waiting for scaledown (up to ${SCALEDOWN_WAIT}s, inactivity=1m)..."
end=$((SECONDS + SCALEDOWN_WAIT))
scaled_down=false
while [ $SECONDS -lt $end ]; do
  label=$($KUBECTL get pod "$POD_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.status\.zeropod\.ctrox\.dev/postgres}' 2>/dev/null || echo "")
  if [ "$label" = "SCALED_DOWN" ]; then
    scaled_down=true
    break
  fi
  sleep 5
done
assert "Pod scaled down (label=SCALED_DOWN)" [ "$scaled_down" = "true" ]

if [ "$scaled_down" != "true" ]; then
  info "Pod labels:"
  $KUBECTL get pod "$POD_NAME" -n "$NAMESPACE" --show-labels 2>/dev/null || true
  fail "Cannot continue — pod did not scale down"
  exit 1
fi

# ---------------------------------------------------------------------------
# 6. Verify pod still Running
# ---------------------------------------------------------------------------
pod_phase=$($KUBECTL get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
assert "Pod phase still Running while checkpointed" [ "$pod_phase" = "Running" ]

# ---------------------------------------------------------------------------
# 7. Trigger restore via TCP and verify data
# ---------------------------------------------------------------------------
# kubectl exec won't trigger restore — zeropod restores on incoming TCP to port 5432.
# CNPG creates a <cluster>-rw Service. Connect through it with a temporary pod.
info "Triggering restore via TCP connection to ${CLUSTER_NAME}-rw service..."

# Get superuser password from CNPG secret
PG_PASSWORD=$($KUBECTL get secret "${CLUSTER_NAME}-superuser" -n "$NAMESPACE" \
  -o jsonpath='{.data.password}' | base64 -d)

# Retry loop: the first TCP connection triggers CRIU restore, which takes a few
# seconds.  The initial psql attempt will likely fail; subsequent ones succeed
# once postgres is back.
RESTORE_ATTEMPTS=5
restored_count=""
for attempt in $(seq 1 $RESTORE_ATTEMPTS); do
  info "  Restore query attempt ${attempt}/${RESTORE_ATTEMPTS}..."

  # Clean up any leftover test pod from a previous attempt
  $KUBECTL delete pod psql-restore-test -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  sleep 2

  raw=$($KUBECTL run psql-restore-test --rm -i --restart=Never \
    --image=postgres:17 -n "$NAMESPACE" \
    --env="PGPASSWORD=${PG_PASSWORD}" \
    --timeout=30s -- \
    psql -h "${CLUSTER_NAME}-rw" -U postgres -t -A -c "SELECT count(*) FROM zeropod_test;" 2>&1) || true

  # Extract the numeric count from output (filter out pod lifecycle messages)
  restored_count=$(echo "$raw" | grep -Eo '^[0-9]+$' | head -1) || true

  if [ -n "$restored_count" ]; then
    info "  Got count: ${restored_count}"
    break
  fi

  info "  No result yet (output: $(echo "$raw" | head -3 | tr '\n' ' '))"
  sleep 5
done

assert "Data intact after restore (${ROW_COUNT} rows)" [ "${restored_count:-0}" -eq "$ROW_COUNT" ]

# Check label flips back
info "Waiting for RUNNING label after restore..."
end=$((SECONDS + 30))
label=""
while [ $SECONDS -lt $end ]; do
  label=$($KUBECTL get pod "$POD_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.status\.zeropod\.ctrox\.dev/postgres}' 2>/dev/null || echo "")
  if [ "$label" = "RUNNING" ]; then
    break
  fi
  sleep 2
done
assert "Pod label back to RUNNING after restore" [ "$label" = "RUNNING" ]

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
