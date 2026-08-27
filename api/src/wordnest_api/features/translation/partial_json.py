"""Pulling a string field out of JSON that is still arriving.

Structured output means the model streams a JSON document, not prose. To show a
translation as it is written, the growing buffer has to be read before it is
valid JSON — so this cannot use `json.loads`.

Pure and free of I/O, so every awkward shape can be tested directly: an escape
split across two chunks, a brace inside a string, a field name that appears in
someone else's value.
"""

_ESCAPES = {
    '"': '"',
    "\\": "\\",
    "/": "/",
    "b": "\b",
    "f": "\f",
    "n": "\n",
    "r": "\r",
    "t": "\t",
}


def extract_partial_string(buffer: str, field: str) -> str | None:
    """Returns as much of `field`'s value as has arrived.

    `None` until the field's opening quote is seen, so a caller can tell "not
    started" from "started and still empty". A trailing incomplete escape is
    withheld rather than guessed at, which is what keeps a `\\uXXXX` split
    across two chunks from surfacing as stray characters.
    """
    start = _value_start(buffer, field)
    if start is None:
        return None

    out: list[str] = []
    index = start
    while index < len(buffer):
        char = buffer[index]
        if char == '"':
            break  # The value is complete.
        if char != "\\":
            out.append(char)
            index += 1
            continue

        # An escape. If the whole of it has not arrived, stop here and let the
        # next chunk complete it.
        if index + 1 >= len(buffer):
            break
        marker = buffer[index + 1]
        if marker == "u":
            if index + 6 > len(buffer):
                break
            try:
                out.append(chr(int(buffer[index + 2 : index + 6], 16)))
            except ValueError:
                return "".join(out)
            index += 6
            continue
        if marker not in _ESCAPES:
            return "".join(out)
        out.append(_ESCAPES[marker])
        index += 2

    return "".join(out)


def _value_start(buffer: str, field: str) -> int | None:
    """Finds the index just past the opening quote of `field`'s value.

    Scans rather than searching for `"field":` so that the same text appearing
    inside another field's *value* cannot be mistaken for the key.
    """
    key = f'"{field}"'
    index = 0
    in_string = False
    escaped = False
    depth = 0

    while index < len(buffer):
        char = buffer[index]

        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue

        if char == '"':
            # Only a key at the top level of the object counts; a nested object
            # may have a field of the same name meaning something else.
            if depth == 1 and buffer.startswith(key, index):
                after = _skip_space(buffer, index + len(key))
                if after < len(buffer) and buffer[after] == ":":
                    value = _skip_space(buffer, after + 1)
                    if value >= len(buffer):
                        return None
                    if buffer[value] != '"':
                        return None  # Not a string field.
                    return value + 1
            in_string = True
            index += 1
            continue

        if char in "{[":
            depth += 1
        elif char in "}]":
            depth -= 1
        index += 1

    return None


def _skip_space(buffer: str, index: int) -> int:
    while index < len(buffer) and buffer[index] in " \t\r\n":
        index += 1
    return index
