#!/usr/bin/env bash
# Stream Tetragon events for the demo namespace. Keep this running in a
# second terminal during the demo. Stop it with Ctrl-C.
#
# Event types you will see (compact output):
#   🚀 process   a program started (execve)
#   💥 exit      a program ended; the last field is its exit code or signal
#   ❓ syscall   a kprobe from one of the demo's TracingPolicies matched
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
exec kubectl -n kube-system exec ds/tetragon -c tetragon -- \
  tetra getevents -o compact --namespace demo "$@"
