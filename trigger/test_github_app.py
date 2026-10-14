#!/usr/bin/env python3
"""Unit tests for GitHub App ingress helpers (no network / no App required)."""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from github_app import should_auto_review_pr, verify_signature  # noqa: E402
from mention_intents import has_mention, parse_intent  # noqa: E402


class IntentTests(unittest.TestCase):
    def test_default_mention_is_review(self) -> None:
        self.assertEqual(parse_intent("@rgctl-bot", "rgctl-bot"), "review")

    def test_explicit_review(self) -> None:
        self.assertEqual(parse_intent("@rgctl-bot review please", "rgctl-bot"), "review")

    def test_fix_refuse(self) -> None:
        self.assertEqual(parse_intent("@rgctl-bot please fix this", "rgctl-bot"), "fix_refuse")
        self.assertEqual(parse_intent("@rgctl-bot implement a patch", "rgctl-bot"), "fix_refuse")

    def test_explain(self) -> None:
        self.assertEqual(
            parse_intent("@rgctl-bot what does this line do?", "rgctl-bot"), "explain"
        )

    def test_no_mention(self) -> None:
        self.assertEqual(parse_intent("just a comment", "rgctl-bot"), "none")
        self.assertFalse(has_mention("hello", "rgctl-bot"))


class SignatureTests(unittest.TestCase):
    def test_valid_signature(self) -> None:
        os.environ["GITHUB_WEBHOOK_SECRET"] = "test-secret"
        # Re-import binding uses module-level secret — call verify with patched secret
        import github_app as ga

        ga.GITHUB_WEBHOOK_SECRET = "test-secret"
        body = b'{"ok":true}'
        dig = hmac.new(b"test-secret", body, hashlib.sha256).hexdigest()
        self.assertTrue(ga.verify_signature(body, f"sha256={dig}"))

    def test_invalid_signature(self) -> None:
        import github_app as ga

        ga.GITHUB_WEBHOOK_SECRET = "test-secret"
        self.assertFalse(ga.verify_signature(b"{}", "sha256=deadbeef"))


class AutoReviewTests(unittest.TestCase):
    def test_draft_skipped(self) -> None:
        ok, reason = should_auto_review_pr(
            {"action": "opened", "pull_request": {"draft": True}}
        )
        self.assertFalse(ok)
        self.assertEqual(reason, "draft")

    def test_synchronize_ok(self) -> None:
        ok, reason = should_auto_review_pr(
            {"action": "synchronize", "pull_request": {"draft": False}}
        )
        self.assertTrue(ok)

    def test_ready_for_review(self) -> None:
        ok, _ = should_auto_review_pr(
            {"action": "ready_for_review", "pull_request": {"draft": True}}
        )
        self.assertTrue(ok)


if __name__ == "__main__":
    unittest.main()
