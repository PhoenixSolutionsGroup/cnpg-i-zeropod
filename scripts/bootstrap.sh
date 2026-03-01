#!/usr/bin/env bash
set -euo pipefail

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
err()   { printf '\033[1;31m[ERR]\033[0m   %s\n' "$*"; exit 1; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE_NAME="cnpg-i-zeropod"
IMAGE_TAG="dev"
NAMESPACE="cnpg-system"
RELEASE_NAME="cnpg-i-zeropod"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# Make kubeconfig readable early (needed for non-root checks below)
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
  sudo chmod 644 /etc/rancher/k3s/k3s.yaml 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Step 1: k3s
# ---------------------------------------------------------------------------
if command -v k3s &>/dev/null && k3s kubectl get nodes &>/dev/null 2>&1; then
  ok "k3s already running"
else
  info "Installing k3s..."
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode=644" sh -
  until k3s kubectl get nodes &>/dev/null 2>&1; do sleep 2; done
  ok "k3s installed"
fi

# Ensure kubectl is available (use k3s kubectl if system kubectl is missing)
if ! command -v kubectl &>/dev/null; then
  warn "kubectl not found, creating alias to k3s kubectl"
  alias kubectl='k3s kubectl'
  KUBECTL="k3s kubectl"
else
  KUBECTL="kubectl"
fi

wait_for_pods() {
  local ns="$1" timeout="${2:-120}"
  local end=$((SECONDS + timeout))
  info "Waiting for pods in ${ns} (up to ${timeout}s)..."
  # First wait for at least one pod to exist
  while [ $SECONDS -lt $end ]; do
    local count
    count=$($KUBECTL get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
      break
    fi
    sleep 5
  done
  # Then wait for all pods to be Ready
  $KUBECTL wait --for=condition=Ready pod --all -n "$ns" --timeout="$((end - SECONDS))s" 2>/dev/null || {
    warn "Some pods not ready yet — current state:"
    $KUBECTL get pods -n "$ns" -o wide 2>/dev/null || true
  }
}

# ---------------------------------------------------------------------------
# Step 2: cert-manager
# ---------------------------------------------------------------------------
if $KUBECTL get namespace cert-manager &>/dev/null 2>&1; then
  ok "cert-manager already installed"
else
  info "Installing cert-manager..."
  $KUBECTL apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
  info "Waiting for cert-manager..."
  $KUBECTL wait --for=condition=Available deployment --all -n cert-manager --timeout=120s
  ok "cert-manager ready"
fi

# ---------------------------------------------------------------------------
# Step 3: zeropod
# ---------------------------------------------------------------------------
if $KUBECTL get runtimeclass zeropod &>/dev/null 2>&1; then
  ok "zeropod RuntimeClass already exists"
else
  info "Labeling node for zeropod..."
  NODE=$($KUBECTL get nodes -o jsonpath='{.items[0].metadata.name}')
  $KUBECTL label node "$NODE" zeropod.ctrox.dev/node=true --overwrite

  info "Installing zeropod (k3s + tracker-ignore-localhost + status-labels)..."
  $KUBECTL apply -k "$REPO_DIR/deploy/zeropod"
  info "Waiting for k3s to come back after restart (this may take a minute)..."
  sleep 10
  attempts=0
  until $KUBECTL get nodes &>/dev/null 2>&1; do
    sleep 5
    ((attempts++))
    if [ "$attempts" -ge 60 ]; then
      err "k3s did not come back after 5 minutes"
    fi
  done
  ok "k3s API server is back"
  wait_for_pods zeropod-system 300
  ok "zeropod installed"
fi

# ---------------------------------------------------------------------------
# Step 4: CNPG operator
# ---------------------------------------------------------------------------
if $KUBECTL get deployment cnpg-controller-manager -n cnpg-system &>/dev/null 2>&1; then
  ok "CNPG operator already installed"
else
  info "Installing CNPG operator v1.26..."
  $KUBECTL apply --server-side -f \
    https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.26/releases/cnpg-1.26.0.yaml
  info "Waiting for CNPG operator..."
  $KUBECTL wait --for=condition=Available deployment/cnpg-controller-manager \
    -n cnpg-system --timeout=120s
  ok "CNPG operator ready"
fi

# ---------------------------------------------------------------------------
# Step 5: Build plugin image
# ---------------------------------------------------------------------------
info "Building plugin container image..."
cd "$REPO_DIR"
docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" .

info "Importing image into k3s containerd..."
docker save "${IMAGE_NAME}:${IMAGE_TAG}" | sudo k3s ctr images import -
ok "Image ${IMAGE_NAME}:${IMAGE_TAG} available in k3s"

# ---------------------------------------------------------------------------
# Step 6: Deploy plugin via Helm
# ---------------------------------------------------------------------------
if ! command -v helm &>/dev/null; then
  info "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

info "Deploying plugin via Helm..."
helm upgrade --install "$RELEASE_NAME" "$REPO_DIR/charts/cnpg-i-zeropod" \
  --namespace "$NAMESPACE" \
  --set image.repository="$IMAGE_NAME" \
  --set image.tag="$IMAGE_TAG" \
  --set image.pullPolicy=Never \
  --wait --timeout=120s
ok "Plugin deployed"

# ---------------------------------------------------------------------------
# Step 7: Restart CNPG operator for plugin discovery
# ---------------------------------------------------------------------------
info "Restarting CNPG operator to discover plugin..."
$KUBECTL rollout restart deployment/cnpg-controller-manager -n cnpg-system
$KUBECTL rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=60s
ok "CNPG operator restarted"

echo ""
echo "============================================"
ok "Bootstrap complete!"
echo "============================================"
echo ""
info "Plugin '${RELEASE_NAME}' is running in namespace '${NAMESPACE}'."
info "Run 'bash scripts/test.sh' to test end-to-end."
