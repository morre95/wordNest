"""Request and response models for the translation endpoint.

These are the contract with the app. They double as the schema handed to the
language model, so a field's description is doing two jobs: documenting the API
and instructing the model.
"""

from typing import Annotated

from pydantic import BaseModel, Field, field_validator

#: A BCP-47 primary tag. The app sends these; anything longer is a region or
#: script subtag we do not translate on.
LanguageCode = Annotated[
    str, Field(min_length=2, max_length=8, pattern=r"^[a-zA-Z-]+$")
]

#: Long enough for anything a person says in one breath, short enough that a
#: single request cannot be used to translate a book.
MAX_SOURCE_CHARACTERS = 1000


class TranslationRequest(BaseModel):
    source_text: str = Field(
        min_length=1,
        max_length=MAX_SOURCE_CHARACTERS,
        description="The finalised utterance, as recognised on the device.",
    )
    source_language: LanguageCode = Field(description="Language spoken.")
    target_language: LanguageCode = Field(description="Language to translate into.")

    @field_validator("source_text")
    @classmethod
    def _reject_blank(cls, value: str) -> str:
        stripped = value.strip()
        if not stripped:
            raise ValueError("source_text cannot be only whitespace")
        return stripped

    @field_validator("source_language", "target_language")
    @classmethod
    def _normalise_language(cls, value: str) -> str:
        return value.strip().lower()


class TranslatedToken(BaseModel):
    """One word from the source sentence, broken down for the glossary."""

    surface_form: str = Field(description="The word exactly as it was said.")
    lemma: str = Field(description="Its dictionary form in the source language.")
    part_of_speech: str = Field(
        description=(
            "Universal Dependencies tag: NOUN, VERB, ADJ, ADV, PRON, DET, ADP, "
            "NUM, CCONJ, SCONJ, PART, INTJ, AUX, PROPN, PUNCT or X."
        )
    )
    target_form: str = Field(
        description="The lemma rendered in the target language, on its own."
    )
    is_content_word: bool = Field(
        description=(
            "True for words worth learning — nouns, verbs, adjectives, adverbs, "
            "proper nouns, interjections. False for grammatical scaffolding."
        )
    )


class TranslationBreakdown(BaseModel):
    """What the language model is asked to produce.

    Kept separate from [TranslationResult] because the model should not be asked
    to echo back the languages it was given.
    """

    translation: str = Field(description="A natural translation of the whole sentence.")
    literal_gloss: str | None = Field(
        default=None,
        description=(
            "A word-for-word rendering, when it differs usefully from the "
            "natural translation. Null when they are the same."
        ),
    )
    tokens: list[TranslatedToken] = Field(
        default_factory=list,
        description="Every word of the source sentence, in the order said.",
    )


class TranslationResult(BaseModel):
    """The `data` half of the response envelope."""

    source_text: str
    source_language: str
    target_language: str
    translation: str
    literal_gloss: str | None = None
    tokens: list[TranslatedToken] = Field(default_factory=list)

    @property
    def content_words(self) -> list[TranslatedToken]:
        return [token for token in self.tokens if token.is_content_word]
