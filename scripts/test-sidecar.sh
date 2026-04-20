#!/usr/bin/env bash
# Smoke-test the sidecar — spawn it, send MCP init + tools/list + tools/call,
# verify responses, then shut down. Exits non-zero on any failure.
set -euo pipefail

REPO_ROOT="$( cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd )"
SIDECAR_DIR="$REPO_ROOT/Sidecar/python"

cd "$SIDECAR_DIR"

# Ensure venv is synced before running
UV_NATIVE_TLS=1 uv sync --native-tls >/dev/null 2>&1 || {
    echo "✗ uv sync failed" >&2
    exit 1
}

python3 <<'PYEOF'
import json
import subprocess
import sys
import os

SIDECAR_DIR = os.environ.get("SIDECAR_DIR", os.getcwd())

def send(proc, msg):
    line = json.dumps(msg) + "\n"
    proc.stdin.write(line.encode())
    proc.stdin.flush()

def recv(proc, expected_id):
    """Read lines until we get a response with matching id. Notifications are skipped."""
    while True:
        raw = proc.stdout.readline()
        if not raw:
            raise RuntimeError("sidecar closed pipe")
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            print(f"  (non-JSON stderr line ignored: {raw!r})", file=sys.stderr)
            continue
        if msg.get("id") == expected_id:
            return msg

proc = subprocess.Popen(
    ["uv", "run", "--native-tls", "python", "-m", "ultron_sidecar"],
    cwd=SIDECAR_DIR,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    env={**os.environ, "UV_NATIVE_TLS": "1"},
)

try:
    # 1) initialize
    send(proc, {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "test-sidecar.sh", "version": "0.0"},
        },
    })
    resp = recv(proc, 1)
    assert "result" in resp, f"initialize failed: {resp}"
    print("✓ initialize")

    # 2) initialized notification
    send(proc, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})

    # 3) tools/list
    send(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    resp = recv(proc, 2)
    tools = resp["result"]["tools"]
    assert any(t["name"] == "ping" for t in tools), f"ping tool not listed: {tools}"
    print(f"✓ tools/list returned {len(tools)} tool(s): {[t['name'] for t in tools]}")

    # 4) tools/call ping
    send(proc, {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {"name": "ping", "arguments": {"message": "hello from swift"}},
    })
    resp = recv(proc, 3)
    content = resp["result"]["content"]
    text = content[0]["text"]
    assert text == "pong: hello from swift", f"unexpected ping response: {text}"
    print(f"✓ tools/call ping → {text!r}")

    print("\nAll checks passed.")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()
PYEOF
