"""Parse @bot mention intents for GitHub App ingress (read-only v1)."""

from __future__ import annotations

import re
from typing import Literal

Intent = Literal["review", "explain", "fix_refuse", "none"]

_FIX_RE = re.compile(
    r"\b(fix|implement|open\s+a\s+pr|create\s+a\s+pr|send\s+a\s+pr|make\s+a\s+pr)\b",
    re.I,
)
_EXPLAIN_RE = re.compile(
    r"\b(explain|what\s+does|why\s+is|how\s+does|can\s+you\s+clarify)\b|\?",
    re.I,
)
_REVIEW_RE = re.compile(r"\breview\b", re.I)


def mention_pattern(bot_slug: str) -> re.Pattern[str]:
    slug = re.escape(bot_slug.lstrip("@").removesuffix("[bot]"))
    return re.compile(rf"(?<!\w)@{slug}(?:\[bot\])?\b", re.I)


def strip_mention(body: str, bot_slug: str) -> str:
    return mention_pattern(bot_slug).sub(" ", body or "").strip()


def has_mention(body: str, bot_slug: str) -> bool:
    return bool(mention_pattern(bot_slug).search(body or ""))


def parse_intent(body: str, bot_slug: str) -> Intent:
    """Classify mention intent. No mention → none. Default mention → review."""
    if not has_mention(body, bot_slug):
        return "none"
    rest = strip_mention(body, bot_slug)
    if not rest:
        return "review"
    if _FIX_RE.search(rest):
        return "fix_refuse"
    if _REVIEW_RE.search(rest):
        return "review"
    if _EXPLAIN_RE.search(rest):
        return "explain"
    return "review"


FIX_REFUSE_MESSAGE = (
    "I'm running in **read-only** mode: I can review and comment, but I cannot "
    "push branches or open fix PRs yet. Re-run a review with `@BOT review`, or "
    "ask `@BOT explain …` about a specific line."
)
