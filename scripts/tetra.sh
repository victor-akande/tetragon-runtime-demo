#!/usr/bin/env bash
# Run the tetra CLI inside the Tetragon agent pod, for example:
#   scripts/tetra.sh tp list
#   scripts/tetra.sh version
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
exec kubectl -n kube-system exec ds/tetragon -c tetragon -- tetra "$@"
