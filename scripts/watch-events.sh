#!/usr/bin/env bash
# Stream Tetragon events for the demo namespace.
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
exec kubectl -n kube-system exec ds/tetragon -c tetragon -- \
  tetra getevents -o compact --namespace demo "$@"
