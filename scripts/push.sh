#!/usr/bin/env bash
set -euo pipefail

REGISTRY="ghcr.io/phoenixsolutionsgroup"
TAG="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
err()   { printf '\033[1;31m[ERR]\033[0m   %s\n' "$*"; exit 1; }

# Build and push Docker image
info "Building cnpg-i-zeropod:${TAG}"
docker build -t cnpg-i-zeropod:"${TAG}" "${REPO_ROOT}"

info "Pushing ${REGISTRY}/cnpg-i-zeropod:${TAG}"
docker tag cnpg-i-zeropod:"${TAG}" "${REGISTRY}/cnpg-i-zeropod:${TAG}"
docker push "${REGISTRY}/cnpg-i-zeropod:${TAG}"
ok "Pushed image ${REGISTRY}/cnpg-i-zeropod:${TAG}"

# Package and push Helm chart
info "Packaging Helm chart"
helm package "${REPO_ROOT}/charts/cnpg-i-zeropod/" -d /tmp

CHART_FILE=$(ls /tmp/cnpg-i-zeropod-*.tgz | head -1)
info "Pushing Helm chart to oci://${REGISTRY}/charts"
helm push "${CHART_FILE}" "oci://${REGISTRY}/charts"
rm -f "${CHART_FILE}"
ok "Pushed chart oci://${REGISTRY}/charts/cnpg-i-zeropod"

# Render and commit zeropod kustomize manifests
info "Rendering zeropod-vke kustomize manifests"
kubectl kustomize "${REPO_ROOT}/deploy/zeropod-vke/" > "${REPO_ROOT}/deploy/zeropod/rendered.yaml"
ok "Rendered deploy/zeropod/rendered.yaml"
