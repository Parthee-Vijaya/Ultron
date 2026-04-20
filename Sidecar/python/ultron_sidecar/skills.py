"""Discover agentskills.io skills from disk and expose each as an MCP tool.

Layout expected under the skills root (default `~/.ultron/skills/`):

    ~/.ultron/skills/
    └── <category>/
        └── <skill-name>/
            └── SKILL.md        # YAML frontmatter + markdown body

SkillManager (from OpenJarvis) handles parsing. A discovered skill is exposed
as an MCP tool whose name is the kebab-cased skill name, prefixed with `skill.`
to keep it separate from direct BaseTool bridges (calculator, think, etc.).

Calling a skill-tool returns the skill's markdown body as instructions the
caller (Claude in agent mode) should follow, optionally combined with a free-
form `context` string the LLM passed in. That follows the agentskills.io model
— skills are LLM instructions, not imperative programs.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any

from mcp.types import TextContent, Tool

log = logging.getLogger("ultron_sidecar.skills")


DEFAULT_SKILLS_DIR = Path.home() / ".ultron" / "skills"


class SkillAdapter:
    """One adapter per discovered skill. Wraps SkillManager.resolve() output."""

    def __init__(self, manager: Any, manifest: Any) -> None:
        self._manager = manager
        self._manifest = manifest

    @property
    def name(self) -> str:
        # All skills get the `skill.` prefix so they're obviously distinct
        # from bridged BaseTool instances in the tools/list output.
        return f"skill.{self._manifest.name}"

    def to_mcp_tool(self) -> Tool:
        description = self._manifest.description or "(no description)"
        tag_hint = ""
        if getattr(self._manifest, "tags", None):
            tag_hint = f" [tags: {', '.join(self._manifest.tags)}]"
        return Tool(
            name=self.name,
            description=f"[skill] {description}{tag_hint}",
            inputSchema={
                "type": "object",
                "properties": {
                    "context": {
                        "type": "string",
                        "description": (
                            "Optional free-form context the caller wants the "
                            "skill to consider (user request, variable bindings, "
                            "prior conversation snippets, etc.)."
                        ),
                    }
                },
            },
        )

    def invoke(self, arguments: dict) -> list[TextContent]:
        context = arguments.get("context") or ""
        body = self._manifest.markdown_content or ""

        lines = [
            f"# Skill: {self._manifest.name}",
            "",
            f"**Description:** {self._manifest.description}",
        ]
        if getattr(self._manifest, "required_capabilities", None):
            lines.append(
                "**Required capabilities:** "
                + ", ".join(self._manifest.required_capabilities)
            )
        if context:
            lines += ["", "## Context from caller", "", context]
        lines += ["", "## Instructions", "", body.strip() or "(empty body)"]

        return [TextContent(type="text", text="\n".join(lines))]


def load_skill_adapters(
    skills_dir: Path = DEFAULT_SKILLS_DIR,
) -> tuple[list[SkillAdapter], Any]:
    """Discover skills. Returns (adapters, manager) — manager kept alive so
    future calls stay valid. Empty list if dir is missing or empty.
    """
    if not skills_dir.exists():
        log.info("skills dir %s does not exist — no skills loaded", skills_dir)
        return [], None
    try:
        from openjarvis.core.events import EventBus
        from openjarvis.skills import SkillManager
    except ImportError as exc:
        log.warning("openjarvis.skills not available: %s", exc)
        return [], None

    try:
        manager = SkillManager(bus=EventBus())
        manager.discover(paths=[skills_dir])
    except Exception:
        log.exception("SkillManager.discover failed for %s", skills_dir)
        return [], None

    names = manager.skill_names()
    if not names:
        log.info("skills dir %s had 0 discovered skills", skills_dir)
        return [], manager

    adapters: list[SkillAdapter] = []
    for name in names:
        try:
            manifest = manager.resolve(name)
            adapters.append(SkillAdapter(manager, manifest))
        except Exception:
            log.exception("failed to adapt skill %s", name)

    log.info(
        "skills: loaded %d from %s: %s",
        len(adapters),
        skills_dir,
        [a.name for a in adapters],
    )
    return adapters, manager
