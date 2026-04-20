# ultron-sidecar

Python sidecar for Ultron. Exposes OpenJarvis skills, connectors, and inference as MCP tools over stdio so the native Swift shell can consume them via its existing `MCPClient`.

## Phase 1a (current)

Minimal MCP server with one `ping` tool. No OpenJarvis bridge yet — that's Phase 2.

## Dev workflow

```bash
# From repo root
cd Sidecar/python
uv sync                     # install deps into .venv
uv run python -m ultron_sidecar   # run the server on stdio
```

The server reads JSON-RPC from stdin and writes responses to stdout. It's meant to be spawned by Ultron's `MCPClient`, not run interactively — but you can smoke-test the handshake with:

```bash
../../scripts/test-sidecar.sh
```

## Wiring into Ultron

Add this to `~/.jarvis/mcp.json`:

```json
{
  "servers": {
    "ultron": {
      "command": "uv",
      "args": [
        "run",
        "--directory",
        "/Users/pavi/Claude projects/Bad/Ultron/Sidecar/python",
        "python",
        "-m",
        "ultron_sidecar"
      ]
    }
  }
}
```

Launch Ultron — the Settings MCP pane will show `ultron` as running with 1 tool (`ping`).

## Next phases

- **Phase 2:** import OpenJarvis from `ThirdParty/openjarvis/`; expose skills + connectors as MCP tools (`bridge.py`)
- **Phase 3:** expose `inference.run` so Swift `MLXProvider` can delegate to OpenJarvis's local-inference router
- **Phase 4:** `agent.morning_digest` returning structured JSON for the Cockpit tile
