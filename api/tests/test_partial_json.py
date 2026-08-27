"""Reading a field out of JSON that has not finished arriving."""

from itertools import pairwise

import pytest

from wordnest_api.features.translation.partial_json import extract_partial_string


def stream(document: str, field: str = "translation") -> list[str | None]:
    """Every value the extractor would report, one character at a time."""
    return [
        extract_partial_string(document[:size], field)
        for size in range(len(document) + 1)
    ]


class TestArrivingText:
    def test_reports_nothing_before_the_field_starts(self) -> None:
        assert extract_partial_string('{"transl', "translation") is None
        assert extract_partial_string('{"translation"', "translation") is None
        assert extract_partial_string('{"translation":', "translation") is None

    def test_reports_an_empty_value_once_the_quote_arrives(self) -> None:
        # "started and still empty" has to be distinguishable from "not
        # started", or the caller cannot tell when to begin showing anything.
        assert extract_partial_string('{"translation":"', "translation") == ""

    def test_grows_as_the_value_arrives(self) -> None:
        assert (
            extract_partial_string('{"translation":"la pan', "translation") == "la pan"
        )

    def test_stops_at_the_closing_quote(self) -> None:
        document = '{"translation":"la panadería","tokens":[]}'

        assert extract_partial_string(document, "translation") == "la panadería"

    def test_never_reports_more_than_has_arrived(self) -> None:
        document = '{"translation":"hola mundo"}'
        values = [value for value in stream(document) if value is not None]

        for earlier, later in pairwise(values):
            assert later.startswith(earlier), f"{earlier!r} -> {later!r}"


class TestEscapes:
    @pytest.mark.parametrize(
        ("escaped", "expected"),
        [
            (r"\"", '"'),
            (r"\\", "\\"),
            (r"\n", "\n"),
            (r"\t", "\t"),
            (r"\/", "/"),
        ],
    )
    def test_decodes_simple_escapes(self, escaped: str, expected: str) -> None:
        document = '{"translation":"a' + escaped + 'b"}'

        assert extract_partial_string(document, "translation") == f"a{expected}b"

    def test_decodes_a_unicode_escape(self) -> None:
        document = r'{"translation":"panadería"}'

        assert extract_partial_string(document, "translation") == "panadería"

    def test_withholds_an_escape_split_across_chunks(self) -> None:
        # A lone trailing backslash is the first half of an escape. Emitting it
        # and correcting it a chunk later is a flicker the reader can see.
        half_arrived = '{"translation":"a' + chr(92)

        assert extract_partial_string(half_arrived, "translation") == "a"
        assert (
            extract_partial_string(r'{"translation":"panader\u00', "translation")
            == "panader"
        )

    def test_a_complete_escape_is_decoded_even_at_the_end(self) -> None:
        both_halves = '{"translation":"a' + chr(92) + chr(92)

        assert extract_partial_string(both_halves, "translation") == "a" + chr(92)

    def test_an_escaped_quote_does_not_end_the_value(self) -> None:
        document = r'{"translation":"she said \"hello\" twice"}'

        assert (
            extract_partial_string(document, "translation") == 'she said "hello" twice'
        )


class TestFindingTheRightField:
    def test_ignores_the_name_appearing_inside_another_value(self) -> None:
        document = '{"note":"the translation is late","translation":"hola"}'

        assert extract_partial_string(document, "translation") == "hola"

    def test_ignores_a_nested_field_of_the_same_name(self) -> None:
        # A token's own fields must not be mistaken for the sentence's.
        document = '{"tokens":[{"translation":"wrong"}],"translation":"right"}'

        assert extract_partial_string(document, "translation") == "right"

    def test_returns_none_for_a_field_that_is_not_a_string(self) -> None:
        assert extract_partial_string('{"translation":42}', "translation") is None
        assert extract_partial_string('{"translation":null}', "translation") is None

    def test_returns_none_for_a_field_that_is_not_there(self) -> None:
        assert extract_partial_string('{"tokens":[]}', "translation") is None

    def test_tolerates_whitespace_around_the_colon(self) -> None:
        document = '{\n  "translation" :  "hola"\n}'

        assert extract_partial_string(document, "translation") == "hola"

    def test_an_empty_buffer_reports_nothing(self) -> None:
        assert extract_partial_string("", "translation") is None
