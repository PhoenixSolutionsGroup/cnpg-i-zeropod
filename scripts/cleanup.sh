#!/usr/bin/env bash
set -euo pipefail

info()  { printf '\033[1;34m[CLEAN]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[CLEAN]\033[0m %s\n' "$*"; }

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
KUBECTL="${KUBECTL:-kubectl}"
NAMESPACE="${1:-default}"

info "Deleting all CNPG clusters in ${NAMESPACE}..."
$KUBECTL delete cluster --all -n "$NAMESPACE" --wait=false 2>/dev/null || true

info "Deleting all CNPG poolers in ${NAMESPACE}..."
$KUBECTL delete pooler --all -n "$NAMESPACE" --wait=false 2>/dev/null || true

info "Deleting leftover pods (bench clients, debug, initdb)..."
$KUBECTL delete pod -n "$NAMESPACE" -l run=psql-bench-client --ignore-not-found 2>/dev/null || true
$KUBECTL delete pod -n "$NAMESPACE" -l run=wake-client --ignore-not-found 2>/dev/null || true
$KUBECTL delete pods -n "$NAMESPACE" --field-selector=status.phase=Succeeded --ignore-not-found 2>/dev/null || true
$KUBECTL delete pods -n "$NAMESPACE" --field-selector=status.phase=Failed --ignore-not-found 2>/dev/null || true

# Wait for instance pods to terminate
info "Waiting for pods to terminate..."
timeout=60
end=$((SECONDS + timeout))
while [ $SECONDS -lt $end ]; do
  count=$($KUBECTL get pods -n "$NAMESPACE" -l cnpg.io/podRole --no-headers 2>/dev/null | wc -l)
  [ "$count" -eq 0 ] && break
  sleep 2
done

# Clean orphaned PVCs
info "Deleting orphaned PVCs..."
$KUBECTL delete pvc --all -n "$NAMESPACE" --wait=false 2>/dev/null || true

remaining=$($KUBECTL get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v -E "kube-|calico|cert-" | wc -l)
ok "Done. ${remaining} pods remaining in ${NAMESPACE}."
