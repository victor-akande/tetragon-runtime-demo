# Troubleshooting

Every problem on this page actually happened while building the demo.

## Preflight

**FAIL: running inside a container.** Tetragon and Cilium load eBPF programs
into the kernel, so they need a machine with its own kernel. An LXC/LXD or
Docker container shares its host's kernel and isn't allowed to load them. A
telltale sign is `swapoff: Not superuser` while you are root. Create a full VM
(KVM, VMware, a cloud instance) instead.

**FAIL: a Kubernetes port is already in use.** Another Kubernetes install is
still running on this VM (for example a node that was once part of a kubeadm
cluster; its kubelet keeps restarting the old control plane on boot). Check
with `ss -ltnp | grep -E ':(6443|10250|10257|10259)'`. If you don't need the
old cluster: back up `/etc/kubernetes`, run `kubeadm reset -f`, run
`systemctl disable --now kubelet`, remove old CNI configs in `/etc/cni/net.d`,
and reboot. A fresh VM avoids all of this.

**WARN: /etc/cni/net.d has other CNI configs.** Leftovers from another
network plugin (for example `10-calico.conflist`). Remove them if nothing else
on the VM uses them. podman's own file (`87-podman-bridge.conflist`) is
expected and ignored.

**FAIL on a kernel config option or BTF.** The kernel can't run Tetragon.
Use the stock Ubuntu kernel (`linux-generic`).

**A registry is unreachable.** The VM needs outbound HTTPS. Check its proxy
and firewall settings.

## Install

**k3s fails to start** (`Job for k3s.service failed`). Run
`journalctl -u k3s --no-pager | grep -iE "error|fatal" | tail -20`. The usual
cause is `bind: address already in use`: another Kubernetes is running (see
above).

**Pods stuck in `ContainerCreating` or `Init:0/6` for minutes.** Images are
still downloading. `setup/prepull-images.sh` exists for this reason and
normally prevents it. To see what's happening:

```bash
kubectl -n kube-system describe pod <pod> | sed -n '/Events:/,$p'
k3s ctr -n k8s.io content active      # run twice; are the byte counts moving?
```

If they barely move, run `setup/prepull-images.sh` and delete the stuck pod.

**`Error: context deadline exceeded` while installing Tetragon.** Same cause:
its images were still downloading. Run `setup/02-install.sh` again; it
removes a failed Tetragon release and continues.

**Cilium pods crash-loop.** Look at
`kubectl -n kube-system logs ds/cilium -c cilium-agent --tail=50`. If the
errors mention the kernel, try the newer Cilium line, which supports the same
k3s version: `CILIUM_VERSION=1.19.11 setup/02-install.sh`.

**Install sanity check fails.**
- `app -> inventory` fails: check that both pods are running with
  `kubectl -n demo get pods`, then `kubectl -n demo logs deploy/webapp`.
- `app -> attacker` fails: check the attacker container with
  `podman ps` and `podman logs ebpf-attacker`. Its IP must be inside
  `10.88.0.0/16`, the podman network the policy allows:
  `podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ebpf-attacker`.
  Watch for policy drops with
  `kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg monitor --type drop`.

**`ErrImageNeverPull` on the webapp pod.** The app image wasn't imported.
Run `k3s ctr -n k8s.io images ls | grep netcheck`; if it's missing, run
`setup/02-install.sh` again.

## Running the demo

**Network policy test fails.**
- A `DENY` check shows `CONNECTED` or `REFUSED`: the policy isn't applied.
  Check `kubectl -n demo get ciliumnetworkpolicies` (both `VALID True`) and
  `kubectl -n kube-system get pods -l k8s-app=cilium`.
- An `ALLOW` check shows `TIMEOUT`: see "Install sanity check fails" above.
- Every webapp check shows `ERROR`: the tripwire lockdown is active and kills
  every connection from the pod. Run `scripts/policy.sh reset` first.
- The drop log shows 0: the checks still count; the drop capture is a
  best-effort extra.

**The attack still works right after applying policies.** They weren't loaded
yet. `scripts/policy.sh list` must show `enabled` for each. `policy.sh apply`
waits for this.

**`tracing policy {block-token-read demo grpc} does not exist`.** You ran
`tetra tp set-mode` without `--domain k8s`. Policies created with kubectl live
in the `k8s` domain. Use `scripts/policy.sh enforce <name>`, which adds it.

**The download looks like it worked even though curl was killed.** An old
`/tmp/kit.sh` from an earlier run was executed. `attack.sh download` deletes
it first; if you type commands by hand, do the same.

**The app's own `/status` call fails (`curl exited with -9`).** The tripwire
lockdown is active (Act 5). That's expected. Run
`scripts/policy.sh reset-tripwire`, or `scripts/demo.sh reset`.

**`attack.sh` says it can't reach the app.** The port-forward died, usually
because the app pod was restarted. `attack.sh` restarts it automatically; if
that fails, see `/tmp/ebpf-demo-port-forward.log`.

**After a reboot, policies are back in monitor mode.** Modes set with
`policy.sh enforce` live in the running Tetragon agent. Re-run the act, or
use `scripts/demo.sh`, which sets the modes it needs.

**`kubectl exec ... -- sh` fails with exit 137.** `block-shell` is enforcing.
`scripts/policy.sh monitor block-shell` or `scripts/demo.sh reset`.

**Events terminal shows `python app.py SIGKILL`.** Not the app dying: it's the
forked copy of the app that was about to become `sh`. `kubectl -n demo get
pods` shows `RESTARTS 0`.
