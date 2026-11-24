#!/usr/bin/env bash
# Step 2 of 3: check this machine can run the demo. Run as root.
# Every FAIL must be fixed before setup/02-install.sh. WARN and INFO lines
# are for your information.
# shellcheck disable=SC2015,SC1091  # ok() never fails; os-release is read at runtime
set -uo pipefail

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
info() { printf '  \033[36mINFO\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILED=1; }
FAILED=0
K=$(uname -r)

echo "System"
if [ -r /etc/os-release ]; then
  . /etc/os-release
  case "${VERSION_ID:-}" in
    22.04|24.04|26.04) ok "$PRETTY_NAME" ;;
    *) warn "$PRETTY_NAME (the guide is written for Ubuntu 22.04 or newer)" ;;
  esac
fi
ok "kernel $K"
VIRT=$(systemd-detect-virt --container 2>/dev/null || true)
if [ -n "$VIRT" ] && [ "$VIRT" != "none" ]; then
  fail "running inside a container ($VIRT): eBPF needs a full VM or bare metal"
else
  ok "not a container ($(systemd-detect-virt 2>/dev/null || echo unknown))"
fi
[ "$(id -u)" -eq 0 ] && ok "running as root" || fail "run as root (sudo -i)"
CPUS=$(nproc); MEM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
[ "$CPUS" -ge 2 ] && ok "$CPUS CPUs" || fail "$CPUS CPU(s); need at least 2"
# A "4 GB" VM reports a little under 4096 MB once the kernel takes its share.
[ "$MEM_MB" -ge 3500 ] && ok "${MEM_MB} MB RAM" || fail "${MEM_MB} MB RAM; need at least 4 GB"
FREE_GB=$(df -Pk / | awk 'NR==2{print int($4/1024/1024)}')
[ "${FREE_GB:-0}" -ge 10 ] && ok "${FREE_GB} GB free on /" || fail "${FREE_GB} GB free on /; need at least 10"
[ "$(swapon --show | wc -l)" -eq 0 ] && ok "swap off" || warn "swap is on; run setup/00-host-prep.sh"

echo "Tools"
for t in curl git jq podman helm; do
  command -v "$t" >/dev/null 2>&1 && ok "$t" || fail "$t missing; run setup/00-host-prep.sh"
done

echo "Nothing else is using the Kubernetes ports"
if [ -x /usr/local/bin/k3s ] && systemctl is-active -q k3s; then
  info "k3s is already running (fine if you are re-running the install)"
else
  if ! command -v ss >/dev/null 2>&1; then
    warn "ss not installed; can't check ports (apt-get install -y iproute2)"
  else
    BUSY=$(ss -ltnpH '( sport = :6443 or sport = :10250 or sport = :10257 or sport = :10259 )')
    [ -z "$BUSY" ] && ok "ports 6443, 10250, 10257, 10259 free" \
      || fail "a Kubernetes port is already in use (old cluster on this VM?):
$BUSY"
  fi
fi
# podman's own network config lives here too (installed by 00-host-prep.sh); that one is fine.
OTHER_CNI=""
for f in /etc/cni/net.d/*; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in *podman*) ;; *) OTHER_CNI="$OTHER_CNI $(basename "$f")" ;; esac
done
[ -z "$OTHER_CNI" ] && ok "no leftover CNI config from another cluster" \
  || warn "/etc/cni/net.d has other CNI configs (${OTHER_CNI# }): leftovers can clash with Cilium"

echo "Kernel features Tetragon needs"
CFG=/boot/config-$K
if [ ! -r "$CFG" ] && [ -r /proc/config.gz ]; then CFG=/tmp/kconfig-$K; zcat /proc/config.gz > "$CFG"; fi
if [ -r "$CFG" ]; then
  for k in CONFIG_BPF_SYSCALL CONFIG_BPF_JIT CONFIG_KPROBES CONFIG_BPF_EVENTS CONFIG_DEBUG_INFO_BTF; do
    grep -q "^$k=y" "$CFG" && ok "$k" || fail "$k not set"
  done
  # Not needed by the demo (its policies use Sigkill only), reported for the curious.
  grep -q "^CONFIG_BPF_KPROBE_OVERRIDE=y" "$CFG" \
    && info "CONFIG_BPF_KPROBE_OVERRIDE=y (the optional Override action would work)" \
    || info "CONFIG_BPF_KPROBE_OVERRIDE not set (fine: the demo uses Sigkill only)"
else
  warn "no kernel config at /boot/config-$K; skipping config checks"
fi
[ -e /sys/kernel/btf/vmlinux ] && ok "BTF (/sys/kernel/btf/vmlinux)" || fail "no BTF: Tetragon needs it"
if grep -qw bpf /sys/kernel/security/lsm 2>/dev/null; then
  info "BPF LSM active (experimental/lsm-policies can be tried)"
else
  info "BPF LSM not active (only matters for experimental/lsm-policies)"
fi
for fn in security_file_open security_socket_connect security_bprm_check; do
  grep -qw "$fn" /proc/kallsyms && ok "kprobe target $fn" || fail "$fn not found in /proc/kallsyms"
done

echo "Filesystems"
mountpoint -q /sys/fs/bpf && ok "bpffs mounted" || warn "bpffs not mounted; run setup/00-host-prep.sh"

echo "Registries reachable (images and charts are downloaded during install)"
for url in https://get.k3s.io https://github.com https://helm.cilium.io https://quay.io/v2/ https://registry-1.docker.io/v2/; do
  if code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$url"); then
    ok "$url (HTTP $code)"
  else
    fail "$url unreachable"
  fi
done

echo
if [ "$FAILED" -eq 0 ]; then
  echo "Preflight passed. Next: setup/02-install.sh"
else
  echo "Preflight found problems (see FAIL lines)."
  exit 1
fi
