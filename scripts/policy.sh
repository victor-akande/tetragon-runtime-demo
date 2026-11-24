#!/usr/bin/env bash
# Manage the demo's Tetragon TracingPolicies.
#
#   scripts/policy.sh apply <file>...     apply policy files and wait until they are enabled
#   scripts/policy.sh remove <file>...    delete policy files
#   scripts/policy.sh enforce <name>      switch a policy to enforce mode (kills processes)
#   scripts/policy.sh monitor <name>      switch a policy to monitor mode (report only)
#   scripts/policy.sh list                show policies, their mode and counters
#   scripts/policy.sh reset-tripwire      clear the tripwire's state (delete + re-apply it)
#   scripts/policy.sh reset               remove all demo policies and restart the app
#
# Two things this script handles for you, both learned the hard way:
#   1. Policies take a few seconds to load. Attacking before they show
#      "enabled" tests nothing. `apply` waits.
#   2. Policies created with kubectl live in Tetragon's "k8s" domain.
#      `tetra tp set-mode` only finds them with --domain k8s.
#
# Note: a mode set with enforce/monitor lives in the running Tetragon agent.
# If the agent restarts, or the policy file is re-applied with changes, the
# policy goes back to the mode written in its YAML (monitor).
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
NS=demo

tetra() { kubectl -n kube-system exec ds/tetragon -c tetragon -- tetra "$@"; }

state_of() { tetra tp list | awk -v n="$1" '$2==n {print $4}'; }

wait_enabled() {
  local name s i
  for name in "$@"; do
    printf 'waiting for %s to load ' "$name"
    for i in $(seq 1 60); do
      s=$(state_of "$name")
      case "$s" in
        enabled) echo " enabled"; continue 2 ;;
        *error*|*fail*)
          echo " $s"
          echo "Policy $name failed to load. Check:" >&2
          echo "  kubectl -n kube-system logs ds/tetragon -c tetragon --since=5m | grep -i $name" >&2
          exit 1 ;;
      esac
      printf '.'; sleep 2
      [ "$i" -eq 60 ] && { echo " timed out (state: ${s:-not listed})" >&2; exit 1; }
    done
  done
}

names_in() {
  # Print the policy names defined in the given files.
  awk '/^metadata:/{m=1; next} m && /^  name:/{print $2; m=0}' "$@"
}

cmd=${1:-}; shift || true
case "$cmd" in
  apply)
    [ $# -gt 0 ] || { echo "usage: $0 apply <file>..." >&2; exit 1; }
    for f in "$@"; do kubectl apply -f "$f"; done
    # shellcheck disable=SC2046
    wait_enabled $(names_in "$@")
    ;;
  remove)
    [ $# -gt 0 ] || { echo "usage: $0 remove <file>..." >&2; exit 1; }
    for f in "$@"; do kubectl delete -f "$f" --ignore-not-found; done
    ;;
  enforce|monitor)
    [ $# -eq 1 ] || { echo "usage: $0 $cmd <policy-name>" >&2; exit 1; }
    tetra tp set-mode --domain k8s -n "$NS" "$1" "$cmd"
    ;;
  list)
    tetra tp list
    ;;
  reset-tripwire)
    found=0
    for f in policies/04-tripwire-observe.yaml policies/05-tripwire-lockdown.yaml; do
      n=$(names_in "$f")
      if kubectl -n "$NS" get tracingpolicynamespaced "$n" >/dev/null 2>&1; then
        kubectl delete -f "$f"
        kubectl apply -f "$f"
        wait_enabled "$n"
        found=1
      fi
    done
    [ "$found" -eq 1 ] || echo "No tripwire policy is applied; nothing to reset."
    ;;
  reset)
    kubectl delete -f policies/ --ignore-not-found
    pkill -f "kubectl.*port-forward.*svc/webapp" 2>/dev/null || true
    kubectl -n "$NS" rollout restart deploy/webapp
    kubectl -n "$NS" rollout status deploy/webapp --timeout=3m
    echo "Reset done: no demo policies, fresh webapp pod."
    ;;
  *)
    sed -n '2,11p' "$0"
    exit 1
    ;;
esac
