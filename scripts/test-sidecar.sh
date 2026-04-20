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

    # 3) tools/list — expect ping + OpenJarvis bridges
    send(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    resp = recv(proc, 2)
    tools = resp["result"]["tools"]
    names = {t["name"] for t in tools}
    for expected in ("ping", "calculator", "think"):
        assert expected in names, f"{expected!r} not listed: {sorted(names)}"
    print(f"✓ tools/list returned {len(tools)} tool(s): {sorted(names)}")

    # 4) tools/call ping
    send(proc, {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {"name": "ping", "arguments": {"message": "hello from swift"}},
    })
    resp = recv(proc, 3)
    text = resp["result"]["content"][0]["text"]
    assert text == "pong: hello from swift", f"unexpected ping response: {text}"
    print(f"✓ tools/call ping → {text!r}")

    # 5) tools/call calculator (OpenJarvis bridged)
    send(proc, {
        "jsonrpc": "2.0",
        "id": 4,
        "method": "tools/call",
        "params": {"name": "calculator", "arguments": {"expression": "2+3*sqrt(16)"}},
    })
    resp = recv(proc, 4)
    text = resp["result"]["content"][0]["text"]
    assert text == "14.0", f"unexpected calculator response: {text}"
    print(f"✓ tools/call calculator(2+3*sqrt(16)) → {text!r}")

    # 6) tools/call think (OpenJarvis bridged, echoes input)
    send(proc, {
        "jsonrpc": "2.0",
        "id": 5,
        "method": "tools/call",
        "params": {"name": "think", "arguments": {"thought": "Phase 2a works"}},
    })
    resp = recv(proc, 5)
    text = resp["result"]["content"][0]["text"]
    assert "Phase 2a works" in text, f"unexpected think response: {text}"
    print(f"✓ tools/call think → {text!r}")

    # 7) skill discovery — only asserts if ~/.ultron/skills/demo/greet-in-danish/ is installed
    if any(t["name"] == "skill.greet-in-danish" for t in tools):
        send(proc, {
            "jsonrpc": "2.0",
            "id": 6,
            "method": "tools/call",
            "params": {
                "name": "skill.greet-in-danish",
                "arguments": {"context": "name: Pavi"},
            },
        })
        resp = recv(proc, 6)
        text = resp["result"]["content"][0]["text"]
        assert "greet-in-danish" in text and "name: Pavi" in text, \
            f"skill output missing expected content: {text[:200]}"
        print("✓ tools/call skill.greet-in-danish → instructions returned with context")
    else:
        print("⊙ skill.greet-in-danish not installed — skipping skill invocation test")

    print("\nAll checks passed.")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()
PYEOF
