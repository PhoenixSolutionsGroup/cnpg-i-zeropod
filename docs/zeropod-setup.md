# Zeropod Setup on k3s

## Install k3s

```bash
curl -sfL https://get.k3s.io | sh -
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER ~/.kube/config
kubectl get nodes
```

## Install Zeropod

We use a kustomize overlay at `deploy/zeropod/kustomization.yaml` that extends the upstream k3s config with:
- `tracker-ignore-localhost` — eBPF skips localhost connections (CNPG instance manager → PG)
- `status-labels` — Enables pod labels that our controller watches
- `probe-binary-name=k3s-server` — eBPF kubelet detection (partially effective, see criu-issues.md)
- Patched installer image for IPC shm fix

```bash
kubectl apply -k deploy/zeropod/
```

Wait for the DaemonSet to be ready:
```bash
kubectl -n zeropod-system get pods -w
```

The installer init container copies the containerd shim binary to the node and configures containerd. It may restart k3s.

## Install CNPG Operator

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.26/releases/cnpg-1.26.0.yaml
kubectl -n cnpg-system get pods -w
```

## Build and Deploy the Plugin

```bash
# Build the plugin image
docker build -t cnpg-i-zeropod:latest .

# Import into k3s
docker save cnpg-i-zeropod:latest -o /tmp/cnpg-i-zeropod.tar
sudo k3s ctr images import /tmp/cnpg-i-zeropod.tar

# Deploy via Helm
helm install cnpg-i-zeropod charts/cnpg-i-zeropod/ -n cnpg-system

# Verify plugin is running
kubectl -n cnpg-system get pods -l app=cnpg-i-zeropod
```

## Building the Patched Zeropod Installer

The zeropod source with our IPC shm cleanup patch is at `~/Code/zeropod-source/`. To rebuild:

```bash
cd ~/Code/zeropod-source
docker build --load -t ghcr.io/ctrox/zeropod-installer:patched -f cmd/installer/Dockerfile .
docker save ghcr.io/ctrox/zeropod-installer:patched -o /tmp/zeropod-installer-patched.tar
sudo k3s ctr images import /tmp/zeropod-installer-patched.tar
```

Then redeploy zeropod to pick up the new installer:
```bash
kubectl apply -k deploy/zeropod/
```

The kustomize overlay sets `images.name=ghcr.io/ctrox/zeropod-installer` → `newTag: patched`.

## Updating the Plugin After Code Changes

```bash
docker build -t cnpg-i-zeropod:latest .
docker save cnpg-i-zeropod:latest -o /tmp/cnpg-i-zeropod.tar
sudo k3s ctr images import /tmp/cnpg-i-zeropod.tar

# Restart plugin and controller deployments
kubectl -n cnpg-system rollout restart deployment/cnpg-i-zeropod
kubectl -n cnpg-system rollout restart deployment/cnpg-i-zeropod-controller
```

## Verifying Plugin Registration

Check the CNPG operator logs for plugin discovery:
```bash
kubectl -n cnpg-system logs deployment/cnpg-controller-manager | grep -i plugin
```

Should see: `"Registered plugin" pluginName="cnpg-i-zeropod.io"`

## kubeconfig Gotcha

After restarting k3s, the kubeconfig at `~/.kube/config` may become stale (wrong port). Fix:
```bash
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown $USER ~/.kube/config
```
