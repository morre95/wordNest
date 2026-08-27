"""Server-side identifiers.

Rows that originate on a device keep the id the device gave them — that is what
makes a push idempotent. This is only for rows the server itself creates.
"""

import uuid


def new_id() -> str:
    return uuid.uuid4().hex
