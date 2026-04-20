"""Entry point. Spawned by Ultron's MCPClient via `uv run python -m ultron_sidecar`."""

import asyncio

from .server import run


def main() -> None:
    asyncio.run(run())


if __name__ == "__main__":
    main()
