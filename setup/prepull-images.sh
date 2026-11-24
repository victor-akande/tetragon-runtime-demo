#!/usr/bin/env bash
# Pre-pull the demo's images with podman and import them into k3s.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=setup/versions.env
. setup/versions.env
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

say() { printf '%s\n' "$*"; }

helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

chart_images() {
  grep -oE 'image: *"?[^" ]+' | sed -E 's/image: *"?//' | sed 's/@sha256.*//'
}
CHART_IMAGES=$( {
  helm template cilium cilium/cilium --version "$CILIUM_VERSION" -n kube-system "${CILIUM_HELM_ARGS[@]}" | chart_images
  helm template tetragon cilium/tetragon --version "$TETRAGON_VERSION" -n kube-system | chart_images
} | sort -u )

K3S_VER=$(k3s --version | awk 'NR==1{print $3}')
K3S_IMAGES=$(curl -fsSL "https://github.com/k3s-io/k3s/releases/download/${K3S_VER/+/%2B}/k3s-images.txt" 2>/dev/null \
  | grep -E 'pause|coredns|local-path|metrics-server' || true)
if [ -z "$K3S_IMAGES" ]; then
  say "warning: could not download k3s-images.txt; using images of running pods instead"
  K3S_IMAGES=$(kubectl get pods -A -o jsonpath='{..image}' 2>/dev/null | tr ' ' '\n' \
    | grep -Ev '^(quay.io/cilium|sha256:)' | sed 's/@sha256.*//' | sort -u || true)
fi

DEMO_IMAGES="docker.io/library/python:3.12-slim"

normalize() {
  case $1 in
    */*/*) echo "$1" ;;
    */*)   echo "docker.io/$1" ;;
    *)     echo "docker.io/library/$1" ;;
  esac
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
HAVE=$(k3s ctr -n k8s.io images ls -q)

for raw in $CHART_IMAGES $K3S_IMAGES $DEMO_IMAGES; do
  img=$(normalize "$raw")
  if printf '%s\n' "$HAVE" | grep -qxF "$img"; then
    say "have    $img"
    continue
  fi
  say "pulling $img"
  podman pull -q "$img" >/dev/null
  podman save -o "$WORK/image.tar" "$img" >/dev/null
  k3s ctr -n k8s.io images import "$WORK/image.tar" >/dev/null
  rm -f "$WORK/image.tar"
done
say "All images are in k3s."
