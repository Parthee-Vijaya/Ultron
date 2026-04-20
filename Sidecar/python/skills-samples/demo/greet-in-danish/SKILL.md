---
name: greet-in-danish
description: Greet someone in Danish with a warm Ultron welcome. Takes a name in the context and composes a greeting.
tags:
  - demo
  - danish
---

When a user asks you to greet someone in Danish, respond with exactly this pattern,
substituting the name from the context:

> Hej, {NAME}! Velkommen til Ultron. Hvad kan jeg hjælpe dig med i dag?

If no name is provided, use "min ven" as a fallback.

This skill is intentionally trivial — its purpose is to demonstrate that
user-installable agentskills.io skills load from `~/.ultron/skills/` and appear
as `skill.<name>` MCP tools to Ultron's agent mode.
