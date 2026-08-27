"""Server-sent events for a translation in progress.

The wire format is one `event:` line and one `data:` line per message, ending
in a blank line. Kept pure so the shape can be tested without a server, and so
the router does not build strings by hand.

Event types, in the order they arrive:

* `delta`     — more of the natural translation. `{"text": "..."}`
* `breakdown` — the finished translation and its word list.
* `error`     — the provider gave up. `{"code": "...", "message": "..."}`
* `done`      — nothing further will arrive. Always last, even after an error,
                so a reader has one place to stop.
"""

import json
from typing import Any


def format_event(event: str, data: dict[str, Any] | None = None) -> str:
    """Renders one SSE message.

    `json.dumps` without `indent` cannot produce a newline inside the payload,
    which is what would otherwise break the one-line `data:` framing.
    """
    payload = json.dumps(data or {}, ensure_ascii=False, separators=(",", ":"))
    return f"event: {event}\ndata: {payload}\n\n"


def delta_event(text: str) -> str:
    return format_event("delta", {"text": text})


def breakdown_event(breakdown: Any) -> str:
    return format_event("breakdown", breakdown)


def error_event(code: str, message: str) -> str:
    return format_event("error", {"code": code, "message": message})


def done_event() -> str:
    return format_event("done")
