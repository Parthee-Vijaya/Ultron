"""Bridge OpenJarvis BaseTool instances into MCP tool definitions.

Each OpenJarvis tool exposes a `ToolSpec` (name, description, JSON-Schema parameters)
and an `execute(**kwargs)` method returning a `ToolResult`. MCP wants `Tool` objects
with a matching shape and a separate `call_tool` handler — this module maps one to
the other so we can register any number of OpenJarvis tools without duplicating
handler code.

Phase 2a scope: zero-auth, zero-network tools only (calculator, think). Phase 2b
adds tools that need engine/config (file ops, http, skill manager). Phase 2c adds
connectors that need OAuth.
"""

from __future__ import annotations

import logging
from typing import Any

from mcp.types import TextContent, Tool

log = logging.getLogger("ultron_sidecar.bridge")


class OpenJarvisToolAdapter:
    """Wraps a single OpenJarvis BaseTool so MCP can introspect + invoke it.

    Instances are held in a dict keyed by tool name; the sidecar's `list_tools`
    enumerates them and `call_tool` dispatches by name.
    """

    def __init__(self, openjarvis_tool: Any) -> None:
        self._tool = openjarvis_tool
        self._spec = openjarvis_tool.spec

    @property
    def name(self) -> str:
        return self._spec.name

    def to_mcp_tool(self) -> Tool:
        """Convert the OpenJarvis ToolSpec into an MCP Tool definition."""
        return Tool(
            name=self._spec.name,
            description=self._spec.description,
            inputSchema=self._spec.parameters or {"type": "object", "properties": {}},
        )

    def invoke(self, arguments: dict) -> list[TextContent]:
        """Run the underlying tool and format the result as MCP content.

        OpenJarvis ToolResult has `.content` (str) and `.success` (bool). If the
        tool fails, we still return TextContent but tag it as an error so the
        MCP client surfaces it distinctly.
        """
        try:
            result = self._tool.execute(**arguments)
        except Exception as exc:
            log.exception("OpenJarvis tool %s raised", self._spec.name)
            return [TextContent(type="text", text=f"Tool error: {exc}")]

        content = getattr(result, "content", None)
        if content is None:
            content = str(result)

        if not getattr(result, "success", True):
            return [TextContent(type="text", text=f"Tool failed: {content}")]

        return [TextContent(type="text", text=str(content))]


def load_bridged_tools() -> dict[str, OpenJarvisToolAdapter]:
    """Import and instantiate the OpenJarvis tools we currently expose.

    Kept as a function (not module-level constants) so import errors for a
    single tool don't crash the whole bridge — each tool is loaded inside its
    own try/except. Missing tools are logged and skipped.
    """
    adapters: dict[str, OpenJarvisToolAdapter] = {}

    _register(adapters, "openjarvis.tools.calculator", "CalculatorTool")
    _register(adapters, "openjarvis.tools.think", "ThinkTool")

    return adapters


def _register(registry: dict[str, OpenJarvisToolAdapter], module_path: str, class_name: str) -> None:
    try:
        module = __import__(module_path, fromlist=[class_name])
        cls = getattr(module, class_name)
        adapter = OpenJarvisToolAdapter(cls())
        registry[adapter.name] = adapter
        log.info("bridge: loaded %s from %s", adapter.name, module_path)
    except Exception as exc:
        log.warning("bridge: failed to load %s.%s: %s", module_path, class_name, exc)
