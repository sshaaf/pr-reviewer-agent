"""Compatibility re-export — prefer `mention_intents` for new code."""

from mention_intents import (  # noqa: F401
    FIX_REFUSE_MESSAGE,
    Intent,
    has_mention,
    mention_pattern,
    parse_intent,
    strip_mention,
)
