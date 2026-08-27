"""Jinja2 environment for the LLM prompt templates.

Prompts live in `prompts/` as templates, not as f-strings in Python, so a change
to what the model is asked shows up as a reviewable diff.
"""

from functools import lru_cache

from jinja2 import Environment, FileSystemLoader, StrictUndefined

from .config import get_settings


@lru_cache
def prompt_environment() -> Environment:
    settings = get_settings()
    return Environment(
        loader=FileSystemLoader(settings.prompts_directory),
        # A missing variable must fail at render time rather than silently
        # producing a prompt with a hole in it.
        undefined=StrictUndefined,
        trim_blocks=True,
        lstrip_blocks=True,
        keep_trailing_newline=True,
        autoescape=False,  # noqa: S701 — prompts are plain text, not HTML.
    )


def render_prompt(template_name: str, **variables: object) -> str:
    return prompt_environment().get_template(template_name).render(**variables)
