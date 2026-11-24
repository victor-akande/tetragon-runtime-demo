"""NetCheck: a deliberately vulnerable internal tool for the demo.

DO NOT deploy this anywhere except a throwaway lab cluster.

/lookup  -> command injection (passes user input to /bin/sh)
/status  -> legitimate use of curl against the internal inventory service
"""
import signal
import subprocess
import sys

from flask import Flask, request

app = Flask(__name__)

INVENTORY_URL = "http://inventory.demo.svc.cluster.local:8080/health"


@app.get("/")
def index():
    return (
        "NetCheck internal tool\n"
        "  /lookup?host=<name>   resolve a hostname\n"
        "  /status               check the inventory service\n"
    )


@app.get("/lookup")
def lookup():
    host = request.args.get("host", "")
    # VULNERABLE ON PURPOSE: user input goes straight into a shell command.
    result = subprocess.run(
        f"getent hosts {host}",
        shell=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    return result.stdout + result.stderr, 200, {"Content-Type": "text/plain"}


@app.get("/status")
def status():
    # Legitimate curl call. The URL is argument index 0 on purpose:
    # policies/02-block-curl-download.yaml allows curl only when
    # argv[1] starts with the internal inventory URL.
    result = subprocess.run(
        ["curl", INVENTORY_URL, "--silent", "--max-time", "3"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    body = result.stdout.strip() or f"curl exited with {result.returncode}"
    return f"inventory: {body}\n", 200, {"Content-Type": "text/plain"}


if __name__ == "__main__":
    # Exit at once on SIGTERM. Without this, the Flask dev server ignores it,
    # Kubernetes waits its 30 s grace period, then SIGKILLs the old pod, which
    # shows up in Tetragon's events as a confusing "python app.py SIGKILL".
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    app.run(host="0.0.0.0", port=5000)
