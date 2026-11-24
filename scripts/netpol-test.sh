#!/usr/bin/env bash
# Prove the Cilium network policy is real and enforced, before showing what
# it can't stop.
#
# Each check opens a TCP connection and reports what happened:
#   CONNECTED  the connection was accepted
#   TIMEOUT    packets were silently dropped (this is what a policy deny looks like)
#   REFUSED    the packets arrived but nothing listens there (so the policy ALLOWED them)
#
# Connections are made with python3, not curl, so the Tetragon policies from
# the later acts never interfere with this test. The one exception is the
# tripwire lockdown (Act 5), which kills every connection from the webapp pod:
# run `scripts/policy.sh reset` first if it is active.
#
# While the checks run, Cilium's own drop log is captured, so you can see the
# agent itself reporting "Policy denied".
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

TIMEOUT=${TIMEOUT:-4}
PROBE='import socket,sys
s=socket.socket(); s.settimeout(float(sys.argv[3]))
try:
    s.connect((sys.argv[1], int(sys.argv[2]))); print("CONNECTED")
except socket.timeout: print("TIMEOUT")
except ConnectionRefusedError: print("REFUSED")
except Exception as e: print("ERROR:" + type(e).__name__)'

ATTACKER_IP=$(podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ebpf-attacker)
# The API server's real address (not the service IP), from its EndpointSlice.
API_IP=$(kubectl get endpointslices -n default -l kubernetes.io/service-name=kubernetes \
  -o jsonpath='{.items[0].endpoints[0].addresses[0]}')
API_PORT=$(kubectl get endpointslices -n default -l kubernetes.io/service-name=kubernetes \
  -o jsonpath='{.items[0].ports[0].port}')

# A throwaway pod that is NOT the webapp, to test the inventory's ingress rule.
PROBE_POD=netpol-probe
cleanup() {
  kubectl -n demo delete pod "$PROBE_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  [ -n "${MON_PID:-}" ] && kill "$MON_PID" 2>/dev/null || true
  rm -f "${MON_LOG:-}"
}
trap cleanup EXIT

kubectl -n demo delete pod "$PROBE_POD" --ignore-not-found >/dev/null 2>&1 || true
# Exits on SIGTERM so the pod goes away at once; a plain `sleep` as PID 1
# ignores it and gets SIGKILLed after the 30 s grace period.
kubectl -n demo run "$PROBE_POD" --image=docker.io/library/python:3.12-slim \
  --image-pull-policy=IfNotPresent --restart=Never --labels=app=netpol-probe \
  --command -- python3 -c 'import signal, sys, time
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
time.sleep(600)' >/dev/null
kubectl -n demo wait --for=condition=Ready "pod/$PROBE_POD" --timeout=90s >/dev/null

MON_LOG=$(mktemp)
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg monitor --type drop >"$MON_LOG" 2>/dev/null &
MON_PID=$!
sleep 3

PASS=0; FAIL=0
check() { # check <from: webapp|probe> <label> <host> <port> <ALLOW|DENY>
  local from=$1 label=$2 host=$3 port=$4 want=$5 got verdict
  if [ "$from" = webapp ]; then
    got=$(kubectl -n demo exec deploy/webapp -- python3 -c "$PROBE" "$host" "$port" "$TIMEOUT" 2>/dev/null || echo ERROR)
  else
    got=$(kubectl -n demo exec "$PROBE_POD" -- python3 -c "$PROBE" "$host" "$port" "$TIMEOUT" 2>/dev/null || echo ERROR)
  fi
  case "$want:$got" in
    ALLOW:CONNECTED|ALLOW:REFUSED|DENY:TIMEOUT) verdict=$'\033[32mPASS\033[0m'; PASS=$((PASS+1)) ;;
    *) verdict=$'\033[31mFAIL\033[0m'; FAIL=$((FAIL+1)) ;;
  esac
  printf '  %-48s %-6s %-10s %s\n' "$label" "$want" "$got" "$verdict"
}

printf '\n\033[1mCilium network policy checks\033[0m\n'
printf '  %-48s %-6s %-10s %s\n' "connection" "policy" "result" ""
check webapp "webapp -> inventory:8080 (its dependency)"      inventory.demo.svc.cluster.local 8080 ALLOW
check webapp "webapp -> attacker:80 (\"partner API\" rule)"   "$ATTACKER_IP" 80   ALLOW
check webapp "webapp -> attacker:8080 (port not allowed)"     "$ATTACKER_IP" 8080 DENY
check webapp "webapp -> Kubernetes API server"                "$API_IP" "$API_PORT" DENY
check probe  "other pod -> webapp:5000 (app port is open)"    webapp.demo.svc.cluster.local 5000 ALLOW
check probe  "other pod -> inventory:8080 (only webapp may)"  inventory.demo.svc.cluster.local 8080 DENY

sleep 2
kill "$MON_PID" 2>/dev/null || true
wait "$MON_PID" 2>/dev/null || true
DROPS=$(grep -c "Policy denied" "$MON_LOG" || true)
printf '\n\033[1mCilium drop log during the checks:\033[0m %s packet(s) dropped with "Policy denied"\n' "$DROPS"
grep "Policy denied" "$MON_LOG" | head -4 | cut -c1-150 | sed 's/^/  /' || true

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All $PASS checks passed: the network policy is enforced."
else
  echo "$FAIL check(s) failed. See docs/TROUBLESHOOTING.md, 'Network policy test fails'."
  exit 1
fi
