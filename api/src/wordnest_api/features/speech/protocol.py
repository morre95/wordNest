"""The frames exchanged with the app over the speech socket.

WordNest's own vocabulary, not the transcription vendor's. The app is never
shown a Deepgram response, so replacing Deepgram is a change to `provider.py`
and nothing else — the same containment the translation slice gives Anthropic.

Client to server:

* binary frames  — raw PCM16, mono, at the sample rate named in the query.
* `finalize`     — the speaker has stopped; transcribe what is left.
* `close`        — abandon the session; the client is discarding this utterance.

Server to client:

* `partial` — more of the current utterance. Replaces the previous partial.
* `final`   — this utterance is settled and will not be revised.
* `error`   — the session cannot continue, or this utterance could not be had.

Kept pure so the shape can be asserted without a server.
"""

from typing import Any, Literal

#: Close codes above 4000 are application-defined. The app distinguishes these
#: because they mean different things to a user: one is worth retrying, one is
#: a session that has to be re-established, and one is a limit they hit.
CLOSE_UNAUTHENTICATED = 4401
CLOSE_RATE_LIMITED = 4429
CLOSE_SESSION_EXPIRED = 4408

ControlType = Literal["finalize", "close"]


def partial_frame(text: str) -> dict[str, Any]:
    return {"type": "partial", "text": text}


def final_frame(text: str, *, confidence: float | None = None) -> dict[str, Any]:
    frame: dict[str, Any] = {"type": "final", "text": text}
    if confidence is not None:
        frame["confidence"] = confidence
    return frame


def error_frame(code: str, message: str) -> dict[str, Any]:
    return {"type": "error", "code": code, "message": message}


def read_control(message: object) -> ControlType | None:
    """The control a text frame carries, or None if it carries nothing we know.

    Unknown frames are ignored rather than fatal: a client from a later version
    must not be able to kill a session by saying something new.
    """
    if not isinstance(message, dict):
        return None
    match message.get("type"):
        case "finalize":
            return "finalize"
        case "close":
            return "close"
        case _:
            return None
