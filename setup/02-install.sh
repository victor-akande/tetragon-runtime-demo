#!/usr/bin/env bash
# Step 3 of 3: install everything. Run as root. Takes about 10 minutes.
#
#   k3s          single-node Kubernetes, with its own CNI turned off
#   Cilium       the CNI (pod networking and network policy)
#   Tetragon     eBPF runtime security (the subject of the demo)
#   demo app     a deliberately vulnerable Flask app, plus an "inventory" service
#   attacker     a podman container OUTSIDE the cluster serving a fake toolkit
#
# Re-runnable: run it again after a failure or a VM reboot.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this as root:  sudo -i, then re-run the script." >&2
  exit 1
fi

# shellcheck source=setup/versions.env
. setup/versions.env
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH=$PATH:/usr/local/bin

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "k3s ($K3S_CHANNEL) without flannel and without its network policy controller"
if ! systemctl is-active -q k3s; then
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_CHANNEL="$K3S_CHANNEL" \
    INSTALL_K3S_EXEC="--flannel-backend=none --disable-network-policy --disable=traefik --disable=servicelb --write-kubeconfig-mode=644" \
    sh -
fi
for _ in $(seq 1 60); do kubectl get nodes >/dev/null 2>&1 && break; sleep 2; done
kubectl get nodes
echo "kubectl: $(command -v kubectl)"

step "Pre-pull images with podman"
setup/prepull-images.sh

step "Cilium $CILIUM_VERSION"
helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null
helm upgrade --install cilium cilium/cilium --version "$CILIUM_VERSION" \
  -n kube-system "${CILIUM_HELM_ARGS[@]}" \
  --wait --timeout 10m
kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl wait --for=condition=Ready nodes --all --timeout=5m

step "Tetragon $TETRAGON_VERSION"
if helm -n kube-system status tetragon 2>/dev/null | grep -q 'STATUS: failed'; then
  echo "Removing a failed earlier Tetragon install"
  helm -n kube-system uninstall tetragon --wait
fi
helm upgrade --install tetragon cilium/tetragon --version "$TETRAGON_VERSION" \
  -n kube-system --wait --timeout 10m
kubectl -n kube-system rollout status ds/tetragon --timeout=5m
kubectl -n kube-system exec ds/tetragon -c tetragon -- tetra version

step "Build the demo app with podman and import it into k3s"
podman build -q -t docker.io/library/netcheck:demo app/ >/dev/null
WORK=$(mktemp -d)
podman save -o "$WORK/netcheck.tar" docker.io/library/netcheck:demo >/dev/null
k3s ctr -n k8s.io images import "$WORK/netcheck.tar" >/dev/null
rm -rf "$WORK"
echo "netcheck:demo imported"

step "Deploy the app, the inventory service and the network policy"
kubectl apply -f k8s/workloads.yaml
kubectl apply -f k8s/network-policy.yaml
kubectl -n demo rollout status deploy/webapp --timeout=5m
kubectl -n demo rollout status deploy/inventory --timeout=5m

step "Attacker server: a podman container outside the cluster"
podman rm -f ebpf-attacker >/dev/null 2>&1 || true
podman run -d --name ebpf-attacker \
  -v "$PWD/attacker/payload:/srv:ro" \
  docker.io/library/python:3.12-slim python -m http.server 80 -d /srv >/dev/null
ATTACKER_IP=$(podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ebpf-attacker)
echo "attacker serving http://$ATTACKER_IP/kit.sh"

step "Sanity checks (both must pass)"
sleep 3
INV=$(kubectl -n demo exec deploy/webapp -- curl -s --max-time 5 http://localhost:5000/status || true)
ATK=$(kubectl -n demo exec deploy/webapp -- curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://$ATTACKER_IP/kit.sh" || true)
echo "app -> inventory: ${INV:-<no answer>}"
echo "app -> attacker:  ${ATK:-<no answer>}"
if [ "$INV" = "inventory: ok" ] && [ "$ATK" = "200" ]; then
  echo
  echo "Install done. Next: docs/GUIDE.md, Step 5 (open two terminals)."
else
  echo
  echo "A sanity check failed. See docs/TROUBLESHOOTING.md, 'Install sanity check fails'."
  exit 1
fi
