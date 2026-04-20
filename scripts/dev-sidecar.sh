#!/usr/bin/env bash
# Run the Ultron sidecar in the foreground for development. Reads MCP
# JSON-RPC on stdin, writes responses on stdout. Useful when you want to
# poke it by hand; for real wiring, let MCPRegistry spawn it via the
# entry in ~/.jarvis/mcp.json.
set -euo pipefail

REPO_ROOT="$( cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd )"
cd "$REPO_ROOT/Sidecar/python"

UV_NATIVE_TLS=1 uv sync --native-tls >&2
exec uv run --native-tls python -m ultron_sidecar
