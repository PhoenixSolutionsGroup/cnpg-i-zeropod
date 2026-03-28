#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# test-multi-container.sh — Test PG + PgBouncer + Kratos + Keto in one zeropod pod
#
# Verifies that zeropod can checkpoint/restore multiple containers in one pod
# and that inter-container wake chains work (e.g., kratos → postgres via localhost).
#
# Usage:
#   bash scripts/test-multi-container.sh
#
# If kratos/keto fail to start, the images may be distroless (no /bin/sh).
# Try oryd/kratos:v1.1.0-alpine and oryd/keto:v0.11.1-alpine instead.
# ---------------------------------------------------------------------------

info()  { printf '\033[1;34m[TEST]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[TEST]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[TEST]\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31m[TEST]\033[0m %s\n' "$*"; }

KUBECTL="${KUBECTL:-kubectl}"
NAMESPACE="${NAMESPACE:-default}"
POD_NAME="multi-container-test"
SCALEDOWN_SECONDS="${SCALEDOWN_SECONDS:-5}"
PG_PASSWORD="testpass123"

cleanup() {
  info "Cleaning up..."
  $KUBECTL delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
  $KUBECTL delete pod test-client -n "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
  $KUBECTL delete configmap pgbouncer-config kratos-config keto-config pg-init \
    -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. ConfigMaps
# ---------------------------------------------------------------------------
info "Creating ConfigMaps..."
$KUBECTL delete configmap pgbouncer-config kratos-config keto-config pg-init \
  -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

# PG init: create Kratos and Keto databases
$KUBECTL create configmap pg-init -n "$NAMESPACE" \
  --from-literal=init.sql='CREATE DATABASE kratos; CREATE DATABASE keto;'

# PgBouncer config
$KUBECTL create configmap pgbouncer-config -n "$NAMESPACE" \
  --from-literal=pgbouncer.ini='
[databases]
postgres = host=127.0.0.1 port=5432 dbname=postgres
kratos = host=127.0.0.1 port=5432 dbname=kratos
keto = host=127.0.0.1 port=5432 dbname=keto

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /tmp/userlist.txt
pool_mode = transaction
max_client_conn = 200
default_pool_size = 5
server_login_retry = 1
query_wait_timeout = 30
admin_users = postgres
' \
  --from-literal=userlist.txt="\"postgres\" \"md5$(printf '%s' "${PG_PASSWORD}postgres" | md5sum | cut -d' ' -f1)\""

# Kratos config (minimal — just enough to start the server)
$KUBECTL create configmap kratos-config -n "$NAMESPACE" \
  --from-literal=kratos.yml='
dsn: postgres://postgres:testpass123@127.0.0.1:6432/kratos?sslmode=disable

serve:
  public:
    base_url: http://0.0.0.0:4433/
    port: 4433
    host: 0.0.0.0
  admin:
    base_url: http://0.0.0.0:4434/
    port: 4434
    host: 0.0.0.0

selfservice:
  default_browser_return_url: http://localhost:4455/

log:
  level: warning

identity:
  default_schema_id: default
  schemas:
    - id: default
      url: file:///etc/kratos/identity.schema.json

courier:
  smtp:
    connection_uri: smtp://localhost:25/?disable_starttls=true
' \
  --from-literal=identity.schema.json='{
  "$id": "https://example.com/person.schema.json",
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Person",
  "type": "object",
  "properties": {
    "traits": {
      "type": "object",
      "properties": {
        "email": {
          "type": "string",
          "format": "email",
          "ory.sh/kratos": {
            "credentials": {
              "password": {
                "identifier": true
              }
            }
          }
        }
      },
      "required": ["email"]
    }
  }
}'

# Keto config (minimal)
$KUBECTL create configmap keto-config -n "$NAMESPACE" \
  --from-literal=keto.yml='
dsn: postgres://postgres:testpass123@127.0.0.1:6432/keto?sslmode=disable

serve:
  read:
    host: 0.0.0.0
    port: 4466
  write:
    host: 0.0.0.0
    port: 4467
'

ok "ConfigMaps created"

# ---------------------------------------------------------------------------
# 2. Create multi-container pod
# ---------------------------------------------------------------------------
info "Creating multi-container pod (scaledown: ${SCALEDOWN_SECONDS}s)..."
$KUBECTL delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
sleep 2

$KUBECTL apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
  annotations:
    zeropod.ctrox.dev/ports-map: "postgres=5432;pgbouncer=6432;kratos=4433;keto=4466"
    zeropod.ctrox.dev/container-names: "postgres,pgbouncer,kratos,keto"
    zeropod.ctrox.dev/scaledown-duration: "${SCALEDOWN_SECONDS}s"
    zeropod.ctrox.dev/proxy-timeout: "30s"
    zeropod.ctrox.dev/connect-timeout: "30s"
    zeropod.ctrox.dev/cpu-requests: '{"postgres":"0","pgbouncer":"0","kratos":"0","keto":"0"}'
    zeropod.ctrox.dev/memory-requests: '{"postgres":"0","pgbouncer":"0","kratos":"0","keto":"0"}'
spec:
  runtimeClassName: zeropod
  containers:
    - name: postgres
      image: postgres:17
      env:
        - name: POSTGRES_PASSWORD
          value: "${PG_PASSWORD}"
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
      ports:
        - containerPort: 5432
      volumeMounts:
        - name: pgdata
          mountPath: /var/lib/postgresql/data
        - name: pg-init
          mountPath: /docker-entrypoint-initdb.d

    - name: pgbouncer
      image: ghcr.io/cloudnative-pg/pgbouncer:1.24.0
      env:
        - name: PGBOUNCER_AUTH_TYPE
          value: md5
      ports:
        - containerPort: 6432
      volumeMounts:
        - name: pgbouncer-config
          mountPath: /etc/pgbouncer-custom
      command: ["/bin/bash", "-c"]
      args:
        - |
          cp /etc/pgbouncer-custom/pgbouncer.ini /tmp/pgbouncer.ini
          cp /etc/pgbouncer-custom/userlist.txt /tmp/userlist.txt
          exec pgbouncer /tmp/pgbouncer.ini

    - name: kratos
      image: oryd/kratos:v1.1.0
      ports:
        - containerPort: 4433
        - containerPort: 4434
      env:
        - name: DSN
          value: "postgres://postgres:${PG_PASSWORD}@127.0.0.1:6432/kratos?sslmode=disable"
        - name: GODEBUG
          value: "multipathtcp=0,pidfd=0"
        - name: SQA_OPT_OUT
          value: "true"
      volumeMounts:
        - name: kratos-config
          mountPath: /etc/kratos
      command: ["/bin/sh", "-c"]
      args:
        - |
          n=0
          until [ \$n -ge 60 ]; do
            kratos migrate sql --yes "\$DSN" 2>/dev/null && break
            n=\$((n + 1))
            sleep 2
          done
          exec kratos serve all -c /etc/kratos/kratos.yml

    - name: keto
      image: oryd/keto:v0.11.1
      ports:
        - containerPort: 4466
        - containerPort: 4467
      env:
        - name: DSN
          value: "postgres://postgres:${PG_PASSWORD}@127.0.0.1:6432/keto?sslmode=disable"
        - name: GODEBUG
          value: "multipathtcp=0,pidfd=0"
        - name: SQA_OPT_OUT
          value: "true"
      volumeMounts:
        - name: keto-config
          mountPath: /etc/keto
      command: ["/bin/sh", "-c"]
      args:
        - |
          mkdir -p /tmp/keto_namespaces
          cd /tmp
          n=0
          until [ \$n -ge 60 ]; do
            keto migrate up -c /etc/keto/keto.yml --yes 2>/dev/null && break
            n=\$((n + 1))
            sleep 2
          done
          exec keto serve -c /etc/keto/keto.yml

  volumes:
    - name: pgdata
      emptyDir: {}
    - name: pg-init
      configMap:
        name: pg-init
    - name: pgbouncer-config
      configMap:
        name: pgbouncer-config
    - name: kratos-config
      configMap:
        name: kratos-config
    - name: keto-config
      configMap:
        name: keto-config
EOF

info "Waiting for pod to be ready..."
$KUBECTL wait --for=condition=Ready "pod/$POD_NAME" -n "$NAMESPACE" --timeout=180s
ok "Pod ready"

# ---------------------------------------------------------------------------
# 3. Create test client and verify all services
# ---------------------------------------------------------------------------
info "Creating test client..."
$KUBECTL delete pod test-client -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
sleep 1
$KUBECTL run test-client --image=alpine:latest --restart=Never -n "$NAMESPACE" --command -- sleep 3600
$KUBECTL wait --for=condition=Ready pod/test-client -n "$NAMESPACE" --timeout=60s
info "Installing test tools..."
$KUBECTL exec test-client -n "$NAMESPACE" -- apk add --no-cache postgresql-client curl >/dev/null 2>&1
ok "Test client ready"

POD_IP=$($KUBECTL get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.podIP}')
info "Pod IP: $POD_IP"

# Wait for PG to accept connections (init scripts may take a while)
info "Waiting for PG to accept connections..."
for i in $(seq 1 60); do
  if $KUBECTL exec test-client -n "$NAMESPACE" -- \
    psql "host=${POD_IP} port=5432 dbname=postgres user=postgres password=${PG_PASSWORD} sslmode=disable" \
    -c "SELECT 1;" >/dev/null 2>&1; then
    ok "Direct PG works"
    break
  fi
  if [ "$i" -eq 60 ]; then
    fail "PG did not become ready within 2 minutes"
    $KUBECTL logs "$POD_NAME" -c postgres -n "$NAMESPACE" --tail=20 2>&1 || true
    exit 1
  fi
  sleep 2
done

# Test PgBouncer
info "Testing PgBouncer connection (port 6432)..."
for i in $(seq 1 30); do
  if $KUBECTL exec test-client -n "$NAMESPACE" -- \
    psql "host=${POD_IP} port=6432 dbname=postgres user=postgres password=${PG_PASSWORD} sslmode=disable" \
    -c "SELECT 'pgbouncer-ok' AS test;" 2>&1; then
    ok "PgBouncer works"
    break
  fi
  if [ "$i" -eq 30 ]; then
    fail "PgBouncer did not become ready"
    exit 1
  fi
  sleep 2
done

# Wait for Kratos
info "Waiting for Kratos (port 4433)..."
for i in $(seq 1 90); do
  if $KUBECTL exec test-client -n "$NAMESPACE" -- \
    curl -sf "http://${POD_IP}:4433/health/alive" >/dev/null 2>&1; then
    ok "Kratos is ready"
    break
  fi
  if [ "$i" -eq 90 ]; then
    fail "Kratos did not become ready within 3 minutes"
    info "Kratos logs:"
    $KUBECTL logs "$POD_NAME" -c kratos -n "$NAMESPACE" --tail=20 2>&1 || true
    exit 1
  fi
  sleep 2
done

# Wait for Keto
info "Waiting for Keto (port 4466)..."
for i in $(seq 1 90); do
  if $KUBECTL exec test-client -n "$NAMESPACE" -- \
    curl -sf "http://${POD_IP}:4466/health/alive" >/dev/null 2>&1; then
    ok "Keto is ready"
    break
  fi
  if [ "$i" -eq 90 ]; then
    fail "Keto did not become ready within 3 minutes"
    info "Keto logs:"
    $KUBECTL logs "$POD_NAME" -c keto -n "$NAMESPACE" --tail=20 2>&1 || true
    exit 1
  fi
  sleep 2
done

# ---------------------------------------------------------------------------
# 4. Wait for checkpoint
# ---------------------------------------------------------------------------
info "Waiting for all containers to checkpoint (${SCALEDOWN_SECONDS}s + buffer)..."
sleep $((SCALEDOWN_SECONDS + 15))

check_status() {
  local container="$1"
  $KUBECTL get pod "$POD_NAME" -n "$NAMESPACE" \
    -o jsonpath="{.metadata.labels.status\.zeropod\.ctrox\.dev/${container}}" 2>/dev/null || echo "none"
}

PG_STATUS=$(check_status postgres)
PGB_STATUS=$(check_status pgbouncer)
KR_STATUS=$(check_status kratos)
KE_STATUS=$(check_status keto)

info "Status — postgres:${PG_STATUS}  pgbouncer:${PGB_STATUS}  kratos:${KR_STATUS}  keto:${KE_STATUS}"

all_down=true
for pair in "postgres:$PG_STATUS" "pgbouncer:$PGB_STATUS" "kratos:$KR_STATUS" "keto:$KE_STATUS"; do
  name="${pair%%:*}"
  status="${pair#*:}"
  if [ "$status" != "SCALED_DOWN" ]; then
    warn "$name did not checkpoint (status: $status)"
    all_down=false
  fi
done
if $all_down; then
  ok "All 4 containers checkpointed!"
fi

# ---------------------------------------------------------------------------
# 5. Cold wake tests
# ---------------------------------------------------------------------------

cold_wake_http() {
  local label="$1" port="$2" path="${3:-/health/alive}" iterations="${4:-3}"
  info ""
  info "=== COLD WAKE TEST: ${label} (port ${port}) ==="
  for i in $(seq 1 "$iterations"); do
    if [ "$i" -gt 1 ]; then
      info "  Waiting for re-checkpoint..."
      sleep $((SCALEDOWN_SECONDS + 10))
    fi

    start_ns=$(date +%s%N)
    result=$($KUBECTL exec test-client -n "$NAMESPACE" -- \
      sh -c '
        for j in $(seq 1 60); do
          resp=$(curl -sf "http://'"${POD_IP}"':'"${port}${path}"'" 2>/dev/null)
          if [ -n "$resp" ]; then
            echo "$resp"
            exit 0
          fi
          sleep 0.2
        done
        echo "FAIL"
      ' 2>/dev/null)
    end_ns=$(date +%s%N)
    ms=$(( (end_ns - start_ns) / 1000000 ))

    if [ "$result" != "FAIL" ]; then
      printf "  Wake %d: %4d ms\n" "$i" "$ms"
      # Show response on first wake to prove DB round-trip
      if [ "$i" -eq 1 ]; then
        info "  Response: $(echo "$result" | head -c 120)..."
      fi
    else
      fail "  Wake $i: FAILED"
    fi
  done
}

cold_wake_pg() {
  local label="$1" port="$2" iterations="${3:-3}"
  info ""
  info "=== COLD WAKE TEST: ${label} (port ${port}) ==="
  for i in $(seq 1 "$iterations"); do
    if [ "$i" -gt 1 ]; then
      info "  Waiting for re-checkpoint..."
      sleep $((SCALEDOWN_SECONDS + 10))
    fi

    start_ns=$(date +%s%N)
    result=$($KUBECTL exec test-client -n "$NAMESPACE" -- \
      sh -c '
        connstr="host='"${POD_IP}"' port='"${port}"' dbname=postgres user=postgres password='"${PG_PASSWORD}"' sslmode=disable"
        for j in $(seq 1 60); do
          out=$(psql "$connstr" -t -A -c "SELECT 1;" 2>&1)
          if echo "$out" | grep -q "^1$"; then
            echo "OK"
            exit 0
          fi
          sleep 0.2
        done
        echo "FAIL"
      ' 2>/dev/null)
    end_ns=$(date +%s%N)
    ms=$(( (end_ns - start_ns) / 1000000 ))

    if [ "$result" = "OK" ]; then
      printf "  Wake %d: %4d ms\n" "$i" "$ms"
    else
      fail "  Wake $i: FAILED"
    fi
  done
}

# Kratos cold wake — /self-service/registration/api creates a flow in the DB
cold_wake_http "Kratos → PgBouncer → PG" 4433 "/self-service/registration/api"
sleep $((SCALEDOWN_SECONDS + 10))

# Keto cold wake — /relation-tuples queries the DB
cold_wake_http "Keto → PgBouncer → PG" 4466 "/relation-tuples"
sleep $((SCALEDOWN_SECONDS + 10))

# PgBouncer cold wake (chain: pgbouncer → PG via localhost)
cold_wake_pg "PgBouncer → PG chain" 6432
sleep $((SCALEDOWN_SECONDS + 10))

# Direct PG cold wake
cold_wake_pg "Direct PG" 5432

# ---------------------------------------------------------------------------
# 6. Final status
# ---------------------------------------------------------------------------
info ""
PG_STATUS=$(check_status postgres)
PGB_STATUS=$(check_status pgbouncer)
KR_STATUS=$(check_status kratos)
KE_STATUS=$(check_status keto)
info "Final — postgres:${PG_STATUS}  pgbouncer:${PGB_STATUS}  kratos:${KR_STATUS}  keto:${KE_STATUS}"

ok ""
ok "Test complete!"
