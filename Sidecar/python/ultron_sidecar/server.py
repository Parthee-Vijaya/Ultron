"""MCP server registration.

Phase 1a scope: one `ping` tool for round-trip verification. No OpenJarvis bridge yet.
OpenJarvis skills, connectors, and inference land in Phase 2+ via bridge modules that
register additional tools against the same `server` instance.
"""

from __future__ import annotations

import logging

from mcp.server import NotificationOptions, Server
from mcp.server.models import InitializationOptions
from mcp.server.stdio import stdio_server
from mcp.types import TextContent, Tool

from . import __version__

log = logging.getLogger("ultron_sidecar")

server: Server = Server("ultron-sidecar")


@server.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
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
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    if name == "ping":
        message = arguments.get("message", "")
        return [TextContent(type="text", text=f"pong: {message}")]
    raise ValueError(f"Unknown tool: {name}")


async def run() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    log.info("ultron-sidecar %s starting on stdio", __version__)
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
