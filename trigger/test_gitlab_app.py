#!/usr/bin/env python3
"""Unit tests for GitLab trigger helpers (no network)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

import app as ga  # noqa: E402
from mention_intents import parse_intent  # noqa: E402


def _mr_payload(
    *,
    action: str = "open",
    state: str = "opened",
    draft: bool = False,
    wip: bool = False,
    oldrev: str | None = "abc",
    last_commit: bool = True,
) -> dict:
    attrs: dict = {
        "action": action,
        "state": state,
        "draft": draft,
        "work_in_progress": wip,
        "iid": 7,
        "target_project_id": 1,
        "source_branch": "feat",
        "target_branch": "main",
    }
    if oldrev is not None:
        attrs["oldrev"] = oldrev
    if last_commit:
        attrs["last_commit"] = {"id": "deadbeef"}
    return {"object_kind": "merge_request", "object_attributes": attrs, "project": {"id": 1}}


def _note_payload(
    *,
    body: str,
    author: str = "alice",
    noteable_type: str = "MergeRequest",
    with_mr: bool = True,
    draft: bool = False,
) -> dict:
    payload: dict = {
        "object_kind": "note",
        "object_attributes": {
            "note": body,
            "noteable_type": noteable_type,
        },
        "user": {"username": author},
        "project": {"id": 1, "http_url_to_repo": "https://gitlab.example/g/p.git"},
    }
    if with_mr:
        payload["merge_request"] = {
            "iid": 7,
            "target_project_id": 1,
            "source_branch": "feat",
            "target_branch": "main",
            "draft": draft,
            "work_in_progress": draft,
            "last_commit": {"id": "deadbeef"},
        }
    return payload


class WipSkipTests(unittest.TestCase):
    def test_wip_skipped(self) -> None:
        ok, reason = ga.should_handle_mr(_mr_payload(wip=True))
        self.assertFalse(ok)
        self.assertEqual(reason, "wip_or_draft")

    def test_draft_skipped(self) -> None:
        ok, reason = ga.should_handle_mr(_mr_payload(draft=True))
        self.assertFalse(ok)
        self.assertEqual(reason, "wip_or_draft")

    def test_ready_ok(self) -> None:
        ok, _ = ga.should_handle_mr(_mr_payload())
        self.assertTrue(ok)


class NoteMentionTests(unittest.TestCase):
    def setUp(self) -> None:
        ga._BOT_USERNAME = "rgctl-bot"
        ga.GITLAB_BOT_USERNAME = "rgctl-bot"

    def test_self_note_ignored(self) -> None:
        with mock.patch.object(ga, "run_full_review") as run:
            with mock.patch.object(ga, "post_mr_note") as post:
                ga.handle_note(
                    _note_payload(body="@rgctl-bot review", author="rgctl-bot")
                )
        run.assert_not_called()
        post.assert_not_called()

    def test_fix_refuse_posts_note(self) -> None:
        with mock.patch.object(ga, "run_full_review") as run:
            with mock.patch.object(ga, "post_mr_note") as post:
                ga.handle_note(_note_payload(body="@rgctl-bot please fix this"))
        run.assert_not_called()
        post.assert_called_once()
        self.assertIn("read-only", post.call_args[0][2].lower())

    def test_explain_posts_note(self) -> None:
        with mock.patch.object(ga, "run_full_review") as run:
            with mock.patch.object(ga, "post_mr_note") as post:
                ga.handle_note(
                    _note_payload(body="@rgctl-bot what does this line do?")
                )
        run.assert_not_called()
        post.assert_called_once()

    def test_review_mention_runs_even_if_draft(self) -> None:
        with mock.patch.object(ga, "run_full_review") as run:
            ga.handle_note(
                _note_payload(body="@rgctl-bot review", draft=True)
            )
        run.assert_called_once()

    def test_default_mention_is_review_intent(self) -> None:
        self.assertEqual(parse_intent("@rgctl-bot", "rgctl-bot"), "review")

    def test_issue_note_without_mr_ignored(self) -> None:
        with mock.patch.object(ga, "run_full_review") as run:
            ga.handle_note(
                _note_payload(
                    body="@rgctl-bot review",
                    noteable_type="Issue",
                    with_mr=False,
                )
            )
        run.assert_not_called()


class ProcessWebhookRoutingTests(unittest.TestCase):
    def test_note_routed(self) -> None:
        with mock.patch.object(ga, "handle_note") as hn:
            ga.process_webhook({"object_kind": "note"})
        hn.assert_called_once()

    def test_mr_routed(self) -> None:
        with mock.patch.object(ga, "process_merge_request") as pm:
            ga.process_webhook({"object_kind": "merge_request"})
        pm.assert_called_once()


if __name__ == "__main__":
    unittest.main()
