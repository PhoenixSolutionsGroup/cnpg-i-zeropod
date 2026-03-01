#!/usr/bin/env bash
set -euo pipefail

REGISTRY="ghcr.io/phoenixsolutionsgroup"
TAG="${1:-dev}"

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
err()   { printf '\033[1;31m[ERR]\033[0m   %s\n' "$*"; exit 1; }

# Build plugin
info "Building cnpg-i-zeropod:${TAG}"
docker build -t cnpg-i-zeropod:"${TAG}" .

# Tag and push
info "Pushing ${REGISTRY}/cnpg-i-zeropod:${TAG}"
docker tag cnpg-i-zeropod:"${TAG}" "${REGISTRY}/cnpg-i-zeropod:${TAG}"
docker push "${REGISTRY}/cnpg-i-zeropod:${TAG}"

ok "Pushed ${REGISTRY}/cnpg-i-zeropod:${TAG}"
