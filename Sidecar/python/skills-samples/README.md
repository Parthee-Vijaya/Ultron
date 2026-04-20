# Sample skills for Ultron

Copy any subdirectory of this folder to `~/.ultron/skills/` — the sidecar
discovers them on next launch and registers each as a `skill.<name>` MCP tool
Ultron's agent mode can invoke.

## Quick demo

```bash
mkdir -p ~/.ultron/skills
cp -r demo/greet-in-danish ~/.ultron/skills/
# Restart Ultron (menu bar → Afslut Ultron, relaunch)
```

Then in agent chat:

> Use the skill.greet-in-danish tool with context "name: Pavi".

The tool returns the skill's markdown instructions; Claude composes a reply
following those instructions.

## Format

Each skill lives at `<category>/<skill-name>/SKILL.md` with YAML frontmatter:

```markdown
---
name: skill-name-in-kebab-case
description: One-line description, ≤1024 chars.
tags:
  - optional
  - list
---

Markdown body — instructions for an LLM to follow when this skill is invoked.
```

Naming rules (from agentskills.io spec):
- Lowercase, kebab-case
- ≤64 chars
- No leading/trailing hyphen, no consecutive hyphens

## More skills

Install from community sources (Hermes, OpenClaw) once Phase 2c lands the
CLI `ultron skill install <source>:<id>` workflow. Until then, drop skill
directories into `~/.ultron/skills/` manually.
