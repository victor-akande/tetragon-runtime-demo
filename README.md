# Network policy said yes: runtime enforcement with Tetragon

A hands-on demo that shows what a Kubernetes network policy **can't** stop, and
how [Tetragon](https://tetragon.io) stops it in the kernel with eBPF.

A deliberately vulnerable app runs behind a sensible Cilium network policy. An
attacker exploits a command-injection bug, steals the pod's service-account
token, reads a secret with it from outside the cluster, and downloads a
toolkit. Every step uses traffic the network policy allows. Then Tetragon
policies stop each step, rolled out the safe way: monitor first, then
enforce, one layer at a time.

## What the demo shows

| Act | What happens | Tetragon feature |
|---|---|---|
| 0 | A test proves the Cilium network policy is enforced: allowed traffic passes, everything else is dropped | (Cilium, not Tetragon) |
| 1 | The attack succeeds with the network policy in place | (none yet; just watching) |
| 2 | Three policies in **monitor** mode report the attack without breaking anything | `policy-mode: monitor` |
| 3 | Policies switched to **enforce**: token read, download and shell are each killed; the app keeps working | `Sigkill`, `matchCmdArgs` (new in 1.8) |
| 4 | A bypass of the argument filter: be honest about limits | `matchCmdArgs` limits |
| 5 | A **stateful tripwire**: reading a decoy credential locks the pod down, including the app's own traffic | stateful tracing policies (new in 1.8) |

## Quick start

On a fresh **Ubuntu 22.04 or newer** VM (a full VM, not a container; 2 vCPU, 4 GB RAM and 20 GB disk minimum), as root:

```bash
sudo -i
git clone https://github.com/victor-akande/tetragon-runtime-demo
cd tetragon-runtime-demo
setup/00-host-prep.sh      # packages, swap off, Helm      (~3 min)
setup/01-preflight.sh      # checks; fix every FAIL         (~10 s)
setup/02-install.sh        # k3s, Cilium, Tetragon, app     (~10-15 min)
```

Then, in **two** terminals (both `sudo -i` and `cd tetragon-runtime-demo`):

```bash
scripts/watch-events.sh    # terminal 1: live Tetragon events
scripts/demo.sh all        # terminal 2: the whole demo, pausing before each command
```

New to Tetragon? Read [docs/CONCEPTS.md](docs/CONCEPTS.md) first (5 minutes),
then follow [docs/GUIDE.md](docs/GUIDE.md) step by step.
[docs/WHAT-HAPPENS.md](docs/WHAT-HAPPENS.md) explains what the vulnerable app
and Tetragon are doing at every step.

## Tested versions

| Component | Version |
|---|---|
| k3s | v1.33 channel (v1.33.13+k3s2) |
| Cilium | 1.18.17 |
| Tetragon | 1.8.0 |

Versions are set in [`setup/versions.env`](setup/versions.env). The full demo
has run end to end with these versions on Ubuntu 24.04 (kernel 6.8) and
openEuler 24.03 (kernel 6.6).

## Repository layout

```
setup/          host prep, preflight checks, install, image pre-pull, teardown
scripts/        demo.sh (narrated runner), netpol-test.sh, attack.sh, policy.sh, watch-events.sh, tetra.sh
policies/       the Tetragon TracingPolicies, one file per layer, heavily commented
k8s/            the demo workloads and the Cilium network policy
app/            the deliberately vulnerable Flask app
attacker/       the harmless fake toolkit the attacker downloads
docs/           CONCEPTS, step-by-step GUIDE, WHAT-HAPPENS at each step, TROUBLESHOOTING
experimental/   BPF LSM versions of the policies (untested)
```

## Safety

- `app/` contains a **command-injection vulnerability on purpose**. Run it
  only on a throwaway VM, never on a shared or internet-facing machine.
- `setup/00-host-prep.sh` turns off swap and ufw. Use a dedicated lab VM.
- The "toolkit" only prints messages. The "API key" and AWS credentials in
  this repo are fake decoys.
