#!/usr/bin/env bash
# Remove the demo, k3s, Cilium and Tetragon from this VM. Run as root.
set -euo pipefail
podman rm -f ebpf-attacker >/dev/null 2>&1 || true
pkill -f "kubectl.*port-forward.*svc/webapp" 2>/dev/null || true
if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
  /usr/local/bin/k3s-uninstall.sh
fi
# k3s-uninstall.sh leaves /etc/cni/net.d alone. Remove Cilium's config and
# restore the configs Cilium switched off by renaming them to *.cilium_bak
# (podman's, for example), so a later install starts from a clean folder.
rm -f /etc/cni/net.d/05-cilium.conflist
for f in /etc/cni/net.d/*.cilium_bak; do
  [ -e "$f" ] || continue
  orig=${f%.cilium_bak}
  if [ -e "$orig" ]; then rm -f "$f"; else mv "$f" "$orig"; fi
done
echo "Done. Reboot to clear leftover Cilium network interfaces and BPF state."
