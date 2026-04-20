"""Bridge OpenJarvis's DigestStore as persistent briefing memory.

Ultron's `/digest` chat command (Phase 4a) generates a briefing client-side
via the active LLM. This module adds three MCP tools so the sidecar can
persist those briefings + serve them back — giving Ultron a "do I remember
what I told you yesterday?" capability across restarts.

MCP tools registered:
    digest.save(text, sources?, model?) → "saved"
    digest.latest()                     → JSON { text, generated_at, sources, model } or "null"
    digest.history(limit=7)             → JSON [ {…}, {…}, … ]

Storage: OpenJarvis's `DigestStore` (SQLite at ~/.openjarvis/digests/digests.db
by default; we redirect to ~/.ultron/digests/digests.db for separation).

All functions run synchronously — DigestStore's SQLite is fast enough that
offloading to a thread would add more overhead than it saves.
"""

from __future__ import annotations

import json
import logging
from datetime import datetime
from pathlib import Path
from typing import Any

from mcp.types import TextContent, Tool

log = logging.getLogger("ultron_sidecar.digest_bridge")

_DIGESTS_DIR = Path.home() / ".ultron" / "digests"
_DB_PATH = _DIGESTS_DIR / "digests.db"


class DigestBridge:
    """Thin wrapper around DigestStore for the MCP surface.

    Lazy-initialises the store on first use so a missing OpenJarvis install
    fails cleanly at tool invocation time rather than sidecar startup.
    """

    def __init__(self) -> None:
        self._store: Any | None = None

    def _ensure_store(self) -> Any:
        if self._store is None:
            from openjarvis.agents.morning_digest import DigestStore

            _DIGESTS_DIR.mkdir(parents=True, exist_ok=True)
            self._store = DigestStore(db_path=str(_DB_PATH))
        return self._store

    def save(self, text: str, sources: list[str] | None = None, model: str = "unknown") -> str:
        from openjarvis.agents.morning_digest import DigestArtifact

        store = self._ensure_store()
        artifact = DigestArtifact(
            text=text,
            audio_path=Path(""),  # we don't generate audio sidecar-side
            sections={"body": text},
            sources_used=sources or [],
            generated_at=datetime.now(),
            model_used=model,
            voice_used="",
            quality_score=0.0,
            evaluator_feedback="",
        )
        store.save(artifact)
        return "saved"

    def latest(self) -> str:
        store = self._ensure_store()
        latest = store.get_latest()
        if latest is None:
            return "null"
        return json.dumps(self._serialise(latest), ensure_ascii=False)

    def history(self, limit: int = 7) -> str:
        store = self._ensure_store()
        items = store.history(limit=limit)
        return json.dumps([self._serialise(item) for item in items], ensure_ascii=False)

    @staticmethod
    def _serialise(artifact: Any) -> dict:
        return {
            "text": artifact.text,
            "generated_at": artifact.generated_at.isoformat(),
            "sources": list(artifact.sources_used),
            "model": artifact.model_used,
            "quality_score": artifact.quality_score,
        }


_BRIDGE = DigestBridge()


def tools() -> list[Tool]:
    return [
        Tool(
            name="digest.save",
            description=(
                "Persist a briefing the user just generated. Give it plain-text "
                "body + optional list of source tags (e.g. ['weather', 'calendar']) "
                "+ which model wrote it. Future calls to digest.latest / digest.history "
                "will return it."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "text": {"type": "string", "description": "Briefing body text"},
                    "sources": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Tags for which data sources fed the briefing",
                    },
                    "model": {"type": "string", "description": "Model name that generated it"},
                },
                "required": ["text"],
            },
        ),
        Tool(
            name="digest.latest",
            description=(
                "Return the most recently saved briefing as JSON { text, generated_at, "
                "sources, model }. Returns the string 'null' when no briefings have "
                "been saved yet."
            ),
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="digest.history",
            description=(
                "Return up to `limit` past briefings newest-first as a JSON array. "
                "Default limit 7. Useful for 'what did yesterday's briefing say about X'."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "limit": {"type": "integer", "description": "Max entries (default 7)"}
                },
            },
        ),
    ]


def dispatch(name: str, arguments: dict) -> list[TextContent]:
    try:
        if name == "digest.save":
            text = arguments.get("text", "")
            sources = arguments.get("sources")
            model = arguments.get("model", "unknown")
            result = _BRIDGE.save(text=text, sources=sources, model=model)
            return [TextContent(type="text", text=result)]
        if name == "digest.latest":
            return [TextContent(type="text", text=_BRIDGE.latest())]
        if name == "digest.history":
            limit = int(arguments.get("limit", 7))
            return [TextContent(type="text", text=_BRIDGE.history(limit=limit))]
    except Exception as exc:
        log.exception("digest_bridge.%s failed", name)
        return [TextContent(type="text", text=f"digest error: {exc}")]
    return [TextContent(type="text", text=f"Unknown digest tool: {name}")]


def handles(name: str) -> bool:
    return name.startswith("digest.")
