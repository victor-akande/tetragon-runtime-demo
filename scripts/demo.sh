#!/usr/bin/env bash
# Narrated demo runner (docs/GUIDE.md, Step 6).
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

say()   { printf '\n\033[1;33m# %s\033[0m\n' "$*"; }
pause() { [ "${NO_PAUSE:-0}" = 1 ] || read -r -p $'\033[2m[Enter]\033[0m ' _; }
run()   { pause; printf '\033[1;32m$ %s\033[0m\n' "$*"; "$@"; }
title() { printf '\n\033[1;7m  %s  \033[0m\n' "$*"; }

P1=policies/01-block-token-read.yaml
P2=policies/02-block-curl-download.yaml
P3=policies/03-block-shell.yaml
P4=policies/04-tripwire-observe.yaml
P5=policies/05-tripwire-lockdown.yaml

act0() {
  title "ACT 0: the network policy is real, and it is enforced"
  say "Allowed connections succeed, denied ones are dropped, and Cilium logs each drop."
  run scripts/netpol-test.sh
}

act1() {
  title "ACT 1: the network policy is in place, and the attack works anyway"
  say "A Cilium network policy protects the app. Let's confirm it's valid."
  run kubectl -n demo get ciliumnetworkpolicies
  say "Now attack through the app's command-injection bug."
  run scripts/attack.sh all
  say "Every step used traffic the policy allows: inbound HTTP to the app."
}

act2() {
  title "ACT 2: monitor first"
  say "Apply three Tetragon policies in monitor mode. They report, they don't kill."
  run scripts/policy.sh apply "$P1" "$P2" "$P3"
  run scripts/policy.sh list
  say "Same attack again. It still works, but watch the events terminal."
  run scripts/attack.sh all
  say "The app's own curl call must NOT match the curl policy."
  run scripts/attack.sh legit
  run scripts/policy.sh list
  say "NMONITOR shows what each policy would have killed."
}

act3() {
  title "ACT 3: enforce, one layer at a time"
  scripts/policy.sh apply "$P1" "$P2" "$P3" >/dev/null
  say "Layer 1: credential access."
  run scripts/policy.sh enforce block-token-read
  run scripts/attack.sh token
  run scripts/attack.sh use-token
  say "Layer 2: tool download, using matchCmdArgs."
  run scripts/policy.sh enforce block-curl-download
  run scripts/attack.sh download
  run scripts/attack.sh legit
  say "Layer 3: execution. No shells at all."
  run scripts/policy.sh enforce block-shell
  run scripts/attack.sh all
  run scripts/policy.sh list
  say "The app itself is still healthy: no restarts."
  run kubectl -n demo get pods
}

act4() {
  title "ACT 4: limits. Argument filters can be bypassed"
  scripts/policy.sh apply "$P1" "$P2" "$P3" >/dev/null
  scripts/policy.sh enforce block-curl-download >/dev/null
  say "Put the shell policy back in monitor mode so commands run again."
  run scripts/policy.sh monitor block-shell
  say "Allowed URL first, attacker URL second. curl fetches both."
  run scripts/attack.sh bypass
}

act5() {
  title "ACT 5: a stateful tripwire (new in Tetragon 1.8)"
  if kubectl -n demo get tracingpolicynamespaced block-shell >/dev/null 2>&1; then
    scripts/policy.sh monitor block-shell >/dev/null
  fi
  scripts/policy.sh remove "$P5" >/dev/null
  say "Observe mode: reading the decoy credentials flags every later connection."
  run scripts/policy.sh apply "$P4"
  run scripts/attack.sh tripwire
  say "Lockdown mode: the same policy with Sigkill."
  run scripts/policy.sh remove "$P4"
  run scripts/policy.sh apply "$P5"
  run scripts/attack.sh tripwire
  say "The cost: state is shared, so the app's own traffic is locked down too."
  run scripts/attack.sh legit
  say "Reset the tripwire and the app works again."
  run scripts/policy.sh reset-tripwire
  run scripts/attack.sh legit
}

case "${1:-}" in
  act0) act0 ;;
  act1) act1 ;;
  act2) act2 ;;
  act3) act3 ;;
  act4) act4 ;;
  act5) act5 ;;
  all)  scripts/policy.sh reset; act0; act1; act2; act3; act4; act5 ;;
  reset) scripts/policy.sh reset ;;
  *) cat >&2 <<'EOF'
usage: scripts/demo.sh <act0|act1|act2|act3|act4|act5|all|reset>
  act0..act5  run one act, pausing before each command
  all         reset, then acts 0 to 5
  reset       remove all demo policies and restart the app
Set NO_PAUSE=1 to run without waiting for Enter.
EOF
     exit 1 ;;
esac
