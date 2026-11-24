#!/usr/bin/env bash
# Prepare a fresh Ubuntu VM for the demo. Run as root.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this as root:  sudo -i, then re-run the script." >&2
  exit 1
fi

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

VIRT=$(systemd-detect-virt --container 2>/dev/null || true)
if [ -n "$VIRT" ] && [ "$VIRT" != "none" ]; then
  echo "This machine is a container ($VIRT), not a VM." >&2
  echo "Tetragon and Cilium need their own kernel: use a full VM (KVM, VMware, cloud instance)." >&2
  exit 1
fi

step "Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q curl ca-certificates git jq podman unzip iproute2

step "Swap off"
swapoff -a || { echo "swapoff failed: are you root on a real VM? (see setup/01-preflight.sh)" >&2; exit 1; }
if grep -qE '^[^#].*\sswap\s' /etc/fstab; then
  cp /etc/fstab /etc/fstab.before-ebpf-demo
  sed -i -E 's/^([^#].*\sswap\s.*)$/# \1/' /etc/fstab
  echo "Commented out swap in /etc/fstab (backup: /etc/fstab.before-ebpf-demo)"
fi
echo "Swap now: $(swapon --show | wc -l) active device(s)"

step "Firewall"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw disable
else
  echo "ufw not active, nothing to do"
fi

step "Kernel settings"
modprobe br_netfilter 2>/dev/null || true
cat >/etc/sysctl.d/90-ebpf-demo.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
sysctl --system >/dev/null
echo "ip_forward=$(sysctl -n net.ipv4.ip_forward)"

step "BPF and debug filesystems"
mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf
mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug
echo "bpffs and debugfs mounted"

step "Helm 3"
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm version --short

echo
echo "Host prep done. Next: setup/01-preflight.sh"
