"""A deterministic stand-in for the language model.

Same input, same output, every time — so tests can assert on exact values, and
so the service can be run end to end with no API key. It does not translate: it
marks each word so a reader can see at a glance that this is not the real thing.
"""

import re

from .schemas import TranslatedToken, TranslationBreakdown

# Letters, with internal apostrophes and hyphens kept: "that's",
# "state-of-the-art". \u2019 is the curly apostrophe speech recognisers emit.
_WORD = re.compile("[^\\W\\d_]+(?:['\u2019-][^\\W\\d_]+)*", re.UNICODE)

#: Words treated as grammatical scaffolding, mirroring what the app's offline
#: extractor drops. Enough to make `is_content_word` meaningful in tests.
_FUNCTION_WORDS = frozenset(
    {
        "a",
        "an",
        "the",
        "and",
        "or",
        "but",
        "if",
        "of",
        "to",
        "in",
        "on",
        "at",
        "by",
        "for",
        "from",
        "with",
        "is",
        "am",
        "are",
        "was",
        "were",
        "be",
        "been",
        "do",
        "does",
        "did",
        "have",
        "has",
        "had",
        "i",
        "you",
        "he",
        "she",
        "it",
        "we",
        "they",
        "this",
        "that",
        "not",
        "no",
    }
)


class FakeTranslationProvider:
    async def translate(
        self,
        *,
        source_text: str,
        source_language_name: str,
        target_language_name: str,
    ) -> TranslationBreakdown:
        words = _WORD.findall(source_text)
        return TranslationBreakdown(
            translation=f"[{target_language_name}] {source_text}",
            literal_gloss=" ".join(f"<{word.lower()}>" for word in words) or None,
            tokens=[
                TranslatedToken(
                    surface_form=word,
                    lemma=word.lower(),
                    part_of_speech=(
                        "DET" if word.lower() in _FUNCTION_WORDS else "NOUN"
                    ),
                    target_form=f"{word.lower()}-{target_language_name.lower()}",
                    is_content_word=word.lower() not in _FUNCTION_WORDS,
                )
                for word in words
            ],
        )
