# Step-by-step guide (Ubuntu 22.04 or newer)

This guide takes you from a brand-new VM to the full demo. Each step says what
to run, what you should see, and what to do if you don't. Expected outputs
below come from a real run of this demo; IP addresses, pod names and counters
will differ slightly on your machine.

New to Tetragon? Read [CONCEPTS.md](CONCEPTS.md) first. For what the app and
Tetragon are doing at every step, see [WHAT-HAPPENS.md](WHAT-HAPPENS.md).

---

## Step 0: create the VM

| | Minimum |
|---|---|
| Machine | a full VM (KVM, VMware, Hyper-V, a cloud instance) or bare metal. Not an LXC/LXD or Docker container: eBPF needs its own kernel |
| OS | Ubuntu 22.04 LTS or newer, server, fresh install |
| CPU | 2 vCPU |
| RAM | 4 GB |
| Disk | 20 GB |
| Network | outbound internet access |

The demo has run end to end on Ubuntu 24.04 (kernel 6.8) and openEuler 24.03
(kernel 6.6).

The install downloads from `get.k3s.io`, `github.com`, `helm.cilium.io`,
`quay.io`, `docker.io`, `deb.debian.org` and `pypi.org`.

Use a **dedicated** VM. The demo app is vulnerable on purpose, and the setup
turns off swap and the ufw firewall.

## Step 1: get the code onto the VM

Everything in this guide runs **as root**. `sudo -i` opens a root shell:

```bash
sudo -i
git clone https://github.com/victor-akande/tetragon-runtime-demo
cd tetragon-runtime-demo
```

No git access? Copy a zip from your laptop with
`scp tetragon-runtime-demo.zip <user>@<vm>:` and then run
`sudo -i`, `apt-get install -y unzip`, and `unzip /home/<user>/tetragon-runtime-demo.zip`.

## Step 2: prepare the host (~3 minutes)

```bash
setup/00-host-prep.sh
```

It installs `podman`, `git`, `jq` and `unzip`, turns off swap and ufw, sets
the network sysctls Kubernetes needs, mounts the BPF filesystem and installs
Helm. It ends with:

```
Host prep done. Next: setup/01-preflight.sh
```

## Step 3: preflight (~10 seconds)

```bash
setup/01-preflight.sh
```

It checks CPU, memory, disk, swap, tools, free Kubernetes ports, the kernel
features Tetragon needs (BPF, kprobes, BTF), the three kernel functions the
policies hook, and that the image registries are reachable.

- **OK** lines are good.
- **INFO** lines are informational (for example whether the kernel supports
  the optional `Override` action; the demo doesn't need it).
- **WARN** lines are worth reading but don't block the install.
- **FAIL** lines must be fixed first. [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
  covers each one.

It ends with `Preflight passed. Next: setup/02-install.sh`.

## Step 4: install (~10-15 minutes)

```bash
setup/02-install.sh
```

What happens, in order:

1. **k3s** installs, with its built-in network plugin and network policy
   controller turned off (Cilium replaces both).
2. **Images are pre-pulled with podman** and imported into k3s. On some
   networks k3s's own image downloads stall for many minutes; podman doesn't.
3. **Cilium** installs and the node becomes `Ready`.
4. **Tetragon 1.8.0** installs. You'll see `CLI version: v1.8.0`.
5. **The demo app** is built with podman. This is the slowest step on a slow
   network, because it downloads Debian packages.
6. **The workloads and network policy** are deployed into namespace `demo`.
7. **The attacker server** starts as a podman container outside the cluster.
8. **Two sanity checks** run.

It must end with:

```
app -> inventory: inventory: ok
app -> attacker:  200

Install done. Next: docs/GUIDE.md, Step 5 (open two terminals).
```

If either check fails, see "Install sanity check fails" in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md). The script is safe to run again.

## Step 5: open two terminals

Open **two SSH sessions** to the VM. In **both**:

```bash
sudo -i
cd tetragon-runtime-demo
```

**Terminal 1** (events), leave this running:

```bash
scripts/watch-events.sh
```

**Terminal 2** (the demo) is where everything below runs.

## Step 6: run the demo

`scripts/demo.sh` runs each act and **pauses before every command**: press
Enter to run it. That leaves you time to explain each step.

```bash
scripts/demo.sh reset   # start clean: no policies, fresh app pod
scripts/demo.sh act0
scripts/demo.sh act1
scripts/demo.sh act2
scripts/demo.sh act3
scripts/demo.sh act4
scripts/demo.sh act5
```

`scripts/demo.sh all` does the reset and all six acts (0 to 5) in one go. Prefer to
type the commands yourself? Each act below lists them.

### Act 0: the network policy is real, and it is enforced

Command: `scripts/netpol-test.sh`

It opens six connections and checks each result against the policy. A denied
connection shows up as `TIMEOUT`, because Cilium drops the packets silently.
While the checks run, it captures Cilium's own drop log as proof.

Expected:

```
Cilium network policy checks
  connection                                       policy result
  webapp -> inventory:8080 (its dependency)        ALLOW  CONNECTED  PASS
  webapp -> attacker:80 ("partner API" rule)       ALLOW  CONNECTED  PASS
  webapp -> attacker:8080 (port not allowed)       DENY   TIMEOUT    PASS
  webapp -> Kubernetes API server                  DENY   TIMEOUT    PASS
  other pod -> webapp:5000 (app port is open)      ALLOW  CONNECTED  PASS
  other pod -> inventory:8080 (only webapp may)    DENY   TIMEOUT    PASS

Cilium drop log during the checks: N packet(s) dropped with "Policy denied"

All 6 checks passed: the network policy is enforced.
```

Talking point: nobody can say the policy was broken. Remember the third and
fourth lines: the pod can't reach the API server, and the attack still works.
Details: [WHAT-HAPPENS.md, Act 0](WHAT-HAPPENS.md#act-0-the-network-policy-is-enforced).

### Act 1: the attack works despite the network policy

What the app and Tetragon are doing: [WHAT-HAPPENS.md](WHAT-HAPPENS.md#act-1-the-attack-with-only-the-network-policy).

Commands: `kubectl -n demo get ciliumnetworkpolicies`, then `scripts/attack.sh all`.

Expected (pod names and ages will differ):

```
NAME        AGE    VALID
inventory   7m1s   True
webapp      7m1s   True

### 1. Recon
uid=0(root) gid=0(root) groups=0(root)
webapp-58dfdbdf84-hr56q

### 2. Steal the service-account token
eyJhbGciOiJSUzI1NiIsImtpZCI...[token shortened]
cat_exit=0

### 3. Use the stolen token from outside the cluster
$ kubectl --token=<stolen> -n demo get secret payments-api-key
sk_live_DEMO_ONLY_not_a_real_key

### 4. Download and run the attacker's kit
curl_exit=0
[kit] downloaded and running as: uid=0(root) gid=0(root) groups=0(root)
[kit] pretend: installing crypto miner...
```

Talking point: the network policy is valid and did its job. The exploit
arrived on the app's allowed HTTP port, the download used the allowed
outbound HTTP rule, and the stolen token was used from outside the cluster.

### Act 2: monitor first

What the app and Tetragon are doing: [WHAT-HAPPENS.md](WHAT-HAPPENS.md#act-2-monitor-mode).

Commands:

```bash
scripts/policy.sh apply policies/01-block-token-read.yaml policies/02-block-curl-download.yaml policies/03-block-shell.yaml
scripts/policy.sh list
scripts/attack.sh all
scripts/attack.sh legit
scripts/policy.sh list
```

`policy.sh apply` **waits until each policy is enabled**. Policies take a few
seconds to load, and attacking before then tests nothing.

Expected: the attack still fully succeeds (monitor mode only reports).
Terminal 1 now shows `❓ syscall` lines for `security_file_open`,
`security_socket_connect` and `security_bprm_check`. The second
`policy.sh list` shows the counters (some columns left out here):

```
NAME                  STATE     MODE      NPOST   NENFORCE   NMONITOR
block-token-read      enabled   monitor   2       0          2
block-curl-download   enabled   monitor   3       0          3
block-shell           enabled   monitor   5       0          5
```

Check one thing in terminal 1: `attack.sh legit` makes the app run its own
`curl http://inventory...` call. That call must produce **no** `❓ syscall`
line. It proves the `matchCmdArgs` rule tells the app's curl apart from the
attacker's.

### Act 3: enforce, one layer at a time

What the app and Tetragon are doing: [WHAT-HAPPENS.md](WHAT-HAPPENS.md#act-3-enforce-one-layer-at-a-time).

Commands and expected results:

| Command | Expected |
|---|---|
| `scripts/policy.sh enforce block-token-read` | `tracing policy "block-token-read" set to mode "enforce"` |
| `scripts/attack.sh token` | no token, `cat_exit=137`, `Killed` |
| `scripts/attack.sh use-token` | `No token captured (blocked?). Nothing to use.` |
| `scripts/policy.sh enforce block-curl-download` | mode set to enforce |
| `scripts/attack.sh download` | `curl_exit=137`, `Killed`, `sh: 0: cannot open /tmp/kit.sh: No such file` |
| `scripts/attack.sh legit` | `inventory: ok` (the app still works) |
| `scripts/policy.sh enforce block-shell` | mode set to enforce |
| `scripts/attack.sh all` | every step comes back empty |
| `scripts/policy.sh list` | `NENFORCE` above 0 for all three |
| `kubectl -n demo get pods` | `webapp` with `RESTARTS 0` |

Exit code 137 means "killed by SIGKILL". In terminal 1 you'll see lines
ending in `SIGKILL`, including `/usr/local/bin/python app.py SIGKILL`. That
is **not** the app dying: it's the forked copy of the app that was about to
become `sh`. The `RESTARTS 0` proves the app is fine.

### Act 4: the bypass

What the app and Tetragon are doing: [WHAT-HAPPENS.md](WHAT-HAPPENS.md#act-4-the-bypass).

Commands: `scripts/policy.sh monitor block-shell`, then `scripts/attack.sh bypass`.

Expected: `ok`, then the full text of `kit.sh`, then `curl_exit=0`.

`matchCmdArgs` checks one argument at a fixed position. Put the allowed URL
first and the attacker's URL second, and curl fetches both. Lesson: argument
filters narrow the blast radius, but they don't replace the execution-layer
policy.

### Act 5: the stateful tripwire

What the app and Tetragon are doing: [WHAT-HAPPENS.md](WHAT-HAPPENS.md#act-5-the-stateful-tripwire).

Commands:

```bash
scripts/policy.sh apply policies/04-tripwire-observe.yaml
scripts/attack.sh tripwire          # creds print, python download succeeds, events flag it
scripts/policy.sh remove policies/04-tripwire-observe.yaml
scripts/policy.sh apply policies/05-tripwire-lockdown.yaml
scripts/attack.sh tripwire          # python download killed: exit=137
scripts/attack.sh legit             # inventory: curl exited with -9
scripts/policy.sh reset-tripwire
scripts/attack.sh legit             # inventory: ok
```

Expected with **lockdown**:

```
$ cat /app/.aws/credentials
[default]
aws_access_key_id = AKIADECOYDECOYDECOY0
...
$ python3 -c "import urllib.request; ..."; echo exit=$?
exit=137
Killed
```

and then `inventory: curl exited with -9` for the app's own call. That's the
trade-off of shared state: once tripped, **every** connection from the pod is
killed, the app's included, until someone resets the tripwire.

## Step 7: reset or remove

| Goal | Command |
|---|---|
| Start the demo over | `scripts/demo.sh reset` |
| Clear only the tripwire | `scripts/policy.sh reset-tripwire` |
| After a VM reboot | `setup/02-install.sh` again (re-runnable; restarts the attacker container) |
| Remove everything | `setup/teardown.sh`, then `reboot` |

After a reboot, or whenever Tetragon restarts, policies go back to the mode
written in their YAML (monitor). `demo.sh` handles that for you.
