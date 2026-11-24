# Experimental: BPF LSM versions of policies 01-03

These use Tetragon `lsmhooks` instead of kprobes. With BPF LSM, `Override`
makes the kernel **reject the call itself** (the file open, connect or exec
fails with an error) instead of killing the process afterwards.

Status: **untested.** They pass the Tetragon 1.8.0 schema, but haven't been
run. In particular, the argument types for the `socket_connect` hook haven't
been checked.

Requirements: `bpf` must appear in `/sys/kernel/security/lsm`
(`setup/01-preflight.sh` reports this). Stock Ubuntu kernels usually don't
enable it; it needs `lsm=...,bpf` on the kernel command line.

Use them instead of `policies/01-03`, not together with them:

```bash
scripts/policy.sh apply experimental/lsm-policies/*.yaml
```

Their names start with `lsm-`, for example
`scripts/policy.sh enforce lsm-block-token-read`.
