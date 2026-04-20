"""MCP server registration.

`ping` is kept as a low-dependency smoke-test tool. Everything else comes from
OpenJarvis via `bridge.load_bridged_tools()`.

Phase 2a ships: calculator, think. Phase 2b+ adds file ops, skill manager,
connectors, inference delegation.
"""

from __future__ import annotations

import logging

from mcp.server import NotificationOptions, Server
from mcp.server.models import InitializationOptions
from mcp.server.stdio import stdio_server
from mcp.types import TextContent, Tool

from . import __version__
from .bridge import load_bridged_tools

log = logging.getLogger("ultron_sidecar")

server: Server = Server("ultron-sidecar")

_BRIDGED = load_bridged_tools()

_PING_TOOL = Tool(
    name="ping",
    description=(
        "Sanity-check tool. Returns 'pong: <message>' to verify the Swift "
        "shell can spawn the sidecar and complete an MCP round-trip."
    ),
    inputSchema={
        "type": "object",
        "properties": {
            "message": {
                "type": "string",
                "description": "Text to echo back",
            }
        },
    },
)


@server.list_tools()
async def list_tools() -> list[Tool]:
    tools: list[Tool] = [_PING_TOOL]
    tools.extend(adapter.to_mcp_tool() for adapter in _BRIDGED.values())
    return tools


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    if name == "ping":
        message = arguments.get("message", "")
        return [TextContent(type="text", text=f"pong: {message}")]

    adapter = _BRIDGED.get(name)
    if adapter is None:
        raise ValueError(f"Unknown tool: {name}")
    return adapter.invoke(arguments)


async def run() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    log.info("ultron-sidecar %s starting on stdio (bridged tools: %s)", __version__, sorted(_BRIDGED.keys()))
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            InitializationOptions(
                server_name="ultron-sidecar",
                server_version=__version__,
                capabilities=server.get_capabilities(
                    notification_options=NotificationOptions(),
                    experimental_capabilities={},
                ),
            ),
        )
