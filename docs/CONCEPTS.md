# Concepts in 5 minutes

You don't need to know Tetragon to run this demo. This page explains the
handful of ideas the demo uses.

## The pieces

**Kubernetes (k3s).** Runs the demo app. k3s is a small, single-binary
Kubernetes distribution, good for a one-VM lab.

**Cilium.** The network plugin (CNI). It connects pods and enforces
**network policy**: rules about which pods may talk to what. Network policy
works at the level of IP addresses, ports and identities. It cannot see what
a process inside an allowed connection is doing.

**eBPF.** A way to run small, safe programs inside the Linux kernel, attached
to events like "a file is being opened" or "a program is starting". Because
they run in the kernel, they see everything, from every container.

**Tetragon.** A Cilium project that uses eBPF for **runtime security**: it
watches what processes do (start programs, open files, open connections) and
can kill a process the moment it does something forbidden.

## Tetragon words used in this demo

**TracingPolicy.** A Kubernetes object (YAML) that tells Tetragon what to
watch and what to do. This demo uses `TracingPolicyNamespaced`, which only
applies to pods in one namespace (`demo`).

**kprobe.** A hook on a kernel function. The demo hooks three functions that
the kernel's security layer calls:

| Kernel function | Runs when | Used by |
|---|---|---|
| `security_file_open` | a file is opened | token-read policy, tripwire |
| `security_socket_connect` | a program opens a network connection | curl policy, tripwire |
| `security_bprm_check` | a program is about to start (execve) | shell policy |

**Selector.** The filter part of a policy: *which* events count. Examples:
`matchArgs` (which file path), `matchBinaries` (which program),
`matchCmdArgs` (which command-line arguments; new in Tetragon 1.8),
`matchStates` (what the policy's state currently is; new in 1.8).

**Action.** What to do on a match. This demo uses:
- `Post`: report an event (the default).
- `Sigkill`: kill the process immediately. The kill lands before the process
  gets back to running its own code, so `cat` never prints the token and
  `curl` never saves the download.
- `UpdateState`: change the policy's state (used by the tripwire).

(Tetragon also has `Override`, which makes the kernel call itself fail. It
needs `CONFIG_BPF_KPROBE_OVERRIDE` in the kernel, which some distributions
leave out, so this demo sticks to `Sigkill`, which works everywhere.)

**Monitor vs enforce mode.** A policy in **monitor** mode only reports what it
*would* have done, and counts it in `NMONITOR`. In **enforce** mode it acts,
counted in `NENFORCE`. Rolling out in monitor mode first is how you find out
whether a policy would break your app before it does.

**Stateful policy (new in 1.8).** A policy can keep a small piece of state
(a number) that one probe sets and another reads. The demo uses it as a
tripwire: "once someone reads the decoy credentials, treat every later
connection as hostile". The state is shared by the whole policy, not tracked
per process, which is why the lockdown also hits the app's own traffic.

## Reading the events terminal

`scripts/watch-events.sh` prints one line per event:

```
🚀 process demo/webapp-...  /usr/bin/cat /var/run/secrets/.../token      a program started
❓ syscall demo/webapp-...  /usr/bin/cat security_file_open              a policy matched
💥 exit    demo/webapp-...  /usr/bin/cat /var/run/secrets/.../token SIGKILL   it was killed
```

The last field of an `exit` line is the exit code (`0` = success) or the
signal that ended the process.
