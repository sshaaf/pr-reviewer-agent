#!/usr/bin/env python3
"""GitHub App webhook trigger (auto PR review + @mention; read-only write-back)."""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import subprocess
import threading
import time
import urllib.error
import urllib.request
from base64 import b64encode
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from github_auth import github_api, installation_token
from mention_intents import (
    FIX_REFUSE_MESSAGE,
    has_mention,
    parse_intent,
    strip_mention,
)

LOG = logging.getLogger("github-trigger")

GITHUB_APP_ID = os.environ.get("GITHUB_APP_ID", "")
GITHUB_APP_PRIVATE_KEY = os.environ.get("GITHUB_APP_PRIVATE_KEY", "")
GITHUB_WEBHOOK_SECRET = os.environ.get("GITHUB_WEBHOOK_SECRET", "")
GITHUB_BOT_SLUG = os.environ.get("GITHUB_BOT_SLUG", "rgctl-bot").lstrip("@")
AGENT_URL = os.environ.get("AGENT_URL", "http://127.0.0.1:4096").rstrip("/")
OPENCODE_USER = os.environ.get("OPENCODE_SERVER_USER", "opencode")
OPENCODE_PASSWORD = os.environ.get("OPENCODE_SERVER_PASSWORD", "")
WORKSPACE = os.environ.get("WORKSPACE", "/workspace/repo")
REVIEW_SCRIPT = os.environ.get(
    "REVIEW_WORKSPACE_SCRIPT", "/app/scripts/review-workspace.sh"
)
LISTEN_HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8080"))
OUTPUT_MODE = os.environ.get("GITHUB_OUTPUT_MODE", "comment")  # comment | check_run
LOCK = threading.Lock()
RECENT: dict[str, float] = {}
DEBOUNCE_SECONDS = int(os.environ.get("DEBOUNCE_SECONDS", "60"))

AUTO_PR_ACTIONS = frozenset({"opened", "synchronize", "reopened", "ready_for_review"})


def _load_private_key() -> str:
    key = GITHUB_APP_PRIVATE_KEY
    if not key:
        path = os.environ.get("GITHUB_APP_PRIVATE_KEY_PATH", "")
        if path and Path(path).is_file():
            key = Path(path).read_text(encoding="utf-8")
    # Support literal \n in env
    return key.replace("\\n", "\n") if key else ""


def verify_signature(raw_body: bytes, signature_header: str | None) -> bool:
    if not GITHUB_WEBHOOK_SECRET:
        LOG.warning("GITHUB_WEBHOOK_SECRET unset — rejecting webhooks")
        return False
    if not signature_header or not signature_header.startswith("sha256="):
        return False
    digest = hmac.new(
        GITHUB_WEBHOOK_SECRET.encode("utf-8"), raw_body, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(f"sha256={digest}", signature_header)


def _basic_auth_header() -> str:
    token = b64encode(f"{OPENCODE_USER}:{OPENCODE_PASSWORD}".encode()).decode()
    return f"Basic {token}"


def _http_json(
    method: str,
    url: str,
    body: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
    timeout: int = 60,
) -> tuple[int, Any]:
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            code = resp.getcode()
            if not raw:
                return code, None
            return code, json.loads(raw.decode())
    except urllib.error.HTTPError as e:
        err_body = e.read().decode(errors="replace")
        LOG.error("HTTP %s %s → %s %s", method, url, e.code, err_body[:500])
        raise


def debounce(key: str) -> bool:
    """Return True if this event should be skipped (debounced)."""
    now = time.time()
    if key in RECENT and now - RECENT[key] < DEBOUNCE_SECONDS:
        LOG.info("Debounced %s", key)
        return True
    RECENT[key] = now
    return False


def load_repo_policy_json(workspace: str) -> str | None:
    root = Path(workspace)
    for rel in (".rgctl/policy.json", "policy.json"):
        path = root / rel
        if path.is_file():
            try:
                text = path.read_text(encoding="utf-8")
                json.loads(text)
                LOG.info("Loaded repo policy from %s", path)
                return text
            except (OSError, json.JSONDecodeError) as e:
                LOG.warning("Ignoring invalid policy at %s: %s", path, e)
    return None


def prepare_workspace_github(
    *,
    repo_url: str,
    target_branch: str,
    source_branch: str,
    head_sha: str,
    github_token: str,
) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "VCS_PROVIDER": "github",
            "REPO_URL": repo_url,
            "GITHUB_TOKEN": github_token,
            "TARGET_BRANCH": target_branch,
            "SOURCE_BRANCH": source_branch,
            "HEAD_SHA": head_sha,
            "WORKSPACE": WORKSPACE,
        }
    )
    # Avoid requiring GitLab token when GitHub-only
    env.setdefault("GITLAB_TOKEN", "")
    LOG.info("Running %s for %s", REVIEW_SCRIPT, repo_url)
    subprocess.run([REVIEW_SCRIPT], check=True, env=env)
    meta_dir = Path(WORKSPACE).parent
    return {
        "repo_url": repo_url,
        "base_ref": (meta_dir / "base_ref").read_text().strip(),
        "head_ref": (meta_dir / "head_ref").read_text().strip(),
    }


def wait_agent_healthy(timeout: int = 120) -> None:
    deadline = time.time() + timeout
    headers = {"Authorization": _basic_auth_header()}
    while time.time() < deadline:
        try:
            code, body = _http_json("GET", f"{AGENT_URL}/global/health", headers=headers)
            if code == 200 and isinstance(body, dict) and body.get("healthy") is True:
                return
        except Exception:
            pass
        time.sleep(2)
    raise RuntimeError("agent health check timed out")


def invoke_skill(
    *,
    repo_url: str,
    pr_number: int,
    base_ref: str,
    head_ref: str,
    github_token: str,
) -> None:
    headers = {"Authorization": _basic_auth_header()}
    wait_agent_healthy()
    _, session = _http_json("POST", f"{AGENT_URL}/session", body={}, headers=headers)
    session_id = (session or {}).get("id") or ((session or {}).get("session") or {}).get(
        "id"
    )
    if not session_id:
        raise RuntimeError(f"no session id: {session}")

    input_json: dict[str, Any] = {
        "repo_url": repo_url,
        "pr_number": pr_number,
        "base_ref": base_ref,
        "head_ref": head_ref,
        "github_token": github_token,
        "gitlab_token": None,
        "policy_json": None,
        "config": {
            "upstream_depth": int(os.environ.get("REVIEW_UPSTREAM_DEPTH", "2")),
            "downstream_depth": int(os.environ.get("REVIEW_DOWNSTREAM_DEPTH", "1")),
            "fanout": int(os.environ.get("REVIEW_FANOUT", "5")),
            "max_symbols": int(os.environ.get("REVIEW_MAX_SYMBOLS", "25")),
            "output_mode": OUTPUT_MODE if OUTPUT_MODE in ("comment", "check_run") else "comment",
            "skip_post": False,
            "post_inline_comments": True,
            "impact_report_path": "IMPACT_REPORT.md",
        },
    }
    policy_text = load_repo_policy_json(WORKSPACE)
    if policy_text is not None:
        input_json["policy_json"] = policy_text

    limits = os.environ.get("RGCTL_WITH_LIMITS", "max-mem-mb=1536,threads=1")
    prompt = f"""Load skill rgctl-pr-reviewer-v2 and execute it.
Repository root is {WORKSPACE} (REPO_PATH). Run all git and rgctl commands there.
Every `rgctl discover` MUST use --with-limits (RGCTL_WITH_LIMITS={limits}; keys max-mem-mb + threads).
If policy_json is set or {WORKSPACE}/policy.json / .rgctl/policy.json exists, run rgctl review check --bisect.
Read REVIEW.md and/or AGENTS.md (repo root or docs/) for soft Concerns when present; never RED from docs alone.
Post to GitHub (output_mode {input_json['config']['output_mode']}) with this note shape:
  1) Top: ## Verdict: <emoji> GREEN|YELLOW|RED — one sentence (ladder in the skill)
  2) Sections 1–4 as usual
  3) End: ## Guidelines with Concerns / Blockers / Open questions / What's fine
Also post §3/§4 line findings as inline Files-tab review comments:
  write .rgctl/line-comments.json then run
  bash /app/scripts/post-inline-comments.sh .rgctl/line-comments.json
Do NOT create branches, push commits, or open new pull requests (read-only).
Also write IMPACT_REPORT.md including ## Verdict + Concerns matching the note.

Input JSON:
{json.dumps(input_json, indent=2)}
"""
    body = {
        "agent": "pr-reviewer",
        "parts": [{"type": "text", "text": prompt}],
    }
    code, _ = _http_json(
        "POST",
        f"{AGENT_URL}/session/{session_id}/prompt_async",
        body=body,
        headers=headers,
        timeout=120,
    )
    if code not in (200, 204):
        raise RuntimeError(f"prompt_async failed HTTP {code}")
    LOG.info("prompt_async accepted session=%s pr=%s", session_id, pr_number)


def post_issue_comment(token: str, owner: str, repo: str, issue_number: int, body: str) -> None:
    github_api(
        "POST",
        f"/repos/{owner}/{repo}/issues/{issue_number}/comments",
        token,
        body={"body": body},
    )


def should_auto_review_pr(payload: dict[str, Any]) -> tuple[bool, str]:
    action = payload.get("action") or ""
    if action not in AUTO_PR_ACTIONS:
        return False, f"skip action={action}"
    pr = payload.get("pull_request") or {}
    if pr.get("draft") is True and action != "ready_for_review":
        return False, "draft"
    return True, "ok"


def run_full_review(
    *,
    installation_id: int,
    owner: str,
    repo: str,
    pr_number: int,
    base_ref: str,
    head_ref: str,
    head_sha: str,
    clone_url: str,
) -> None:
    key = f"{installation_id}:{owner}/{repo}:{pr_number}:{head_sha}"
    if debounce(key):
        return
    if not LOCK.acquire(blocking=False):
        LOG.warning("Review already in progress; skipping %s", key)
        return
    try:
        pem = _load_private_key()
        if not GITHUB_APP_ID or not pem:
            raise RuntimeError("GITHUB_APP_ID / GITHUB_APP_PRIVATE_KEY required")
        token = installation_token(GITHUB_APP_ID, pem, installation_id)
        meta = prepare_workspace_github(
            repo_url=clone_url,
            target_branch=base_ref,
            source_branch=head_ref,
            head_sha=head_sha,
            github_token=token,
        )
        os.environ["REPO_PATH"] = WORKSPACE
        invoke_skill(
            repo_url=clone_url,
            pr_number=pr_number,
            base_ref=meta["base_ref"],
            head_ref=meta["head_ref"],
            github_token=token,
        )
    except Exception:
        LOG.exception("GitHub review failed for %s", key)
    finally:
        LOCK.release()


def handle_pull_request(payload: dict[str, Any]) -> None:
    ok, reason = should_auto_review_pr(payload)
    if not ok:
        LOG.info("Ignoring pull_request: %s", reason)
        return
    pr = payload["pull_request"]
    repo = payload["repository"]
    installation_id = int((payload.get("installation") or {}).get("id") or 0)
    if not installation_id:
        LOG.error("Missing installation.id")
        return
    owner = repo["owner"]["login"]
    name = repo["name"]
    run_full_review(
        installation_id=installation_id,
        owner=owner,
        repo=name,
        pr_number=int(pr["number"]),
        base_ref=pr["base"]["ref"],
        head_ref=pr["head"]["ref"],
        head_sha=pr["head"]["sha"],
        clone_url=repo.get("clone_url") or f"https://github.com/{owner}/{name}.git",
    )


def _comment_author_is_bot(payload: dict[str, Any]) -> bool:
    sender = payload.get("sender") or {}
    if sender.get("type") == "Bot":
        return True
    login = (sender.get("login") or "").lower()
    slug = GITHUB_BOT_SLUG.lower()
    if login in (slug, f"{slug}[bot]"):
        return True
    return False


def handle_mention(payload: dict[str, Any], *, event: str) -> None:
    if _comment_author_is_bot(payload):
        LOG.info("Ignoring bot self-comment")
        return
    comment = payload.get("comment") or {}
    body = comment.get("body") or ""
    if not has_mention(body, GITHUB_BOT_SLUG):
        return

    installation_id = int((payload.get("installation") or {}).get("id") or 0)
    repo = payload.get("repository") or {}
    owner = (repo.get("owner") or {}).get("login") or ""
    name = repo.get("name") or ""
    intent = parse_intent(body, GITHUB_BOT_SLUG)
    LOG.info("Mention intent=%s event=%s", intent, event)

    pem = _load_private_key()
    token = installation_token(GITHUB_APP_ID, pem, installation_id) if installation_id else ""

    # Resolve PR association
    pr = payload.get("pull_request")
    issue = payload.get("issue") or {}
    pr_number = None
    if pr:
        pr_number = int(pr["number"])
    elif issue.get("pull_request"):
        pr_number = int(issue["number"])
    elif event == "pull_request_review_comment":
        pr_number = int((payload.get("pull_request") or {}).get("number") or 0) or None

    issue_number = int(issue.get("number") or pr_number or 0)

    if intent == "fix_refuse":
        msg = FIX_REFUSE_MESSAGE.replace("@BOT", f"@{GITHUB_BOT_SLUG}")
        if owner and name and issue_number:
            post_issue_comment(token, owner, name, issue_number, msg)
        return

    if intent == "explain":
        if not (owner and name and issue_number):
            return
        q = strip_mention(body, GITHUB_BOT_SLUG)
        reply = (
            f"_(Explain mode — read-only.)_ I received: {q[:500]}\n\n"
            "For a full rgctl impact review on a pull request, comment "
            f"`@{GITHUB_BOT_SLUG} review`. I cannot open fix PRs in this mode."
        )
        # Prefer reply in PR conversation; line-thread reply would need review comment API
        post_issue_comment(token, owner, name, issue_number, reply)
        return

    # review
    if not pr_number:
        if owner and name and issue_number:
            post_issue_comment(
                token,
                owner,
                name,
                issue_number,
                f"Full review needs a **pull request**. Open a PR, then comment "
                f"`@{GITHUB_BOT_SLUG} review`.",
            )
        return

    # Fetch PR details for head/base
    code, pr_body = github_api("GET", f"/repos/{owner}/{name}/pulls/{pr_number}", token)
    if code != 200 or not isinstance(pr_body, dict):
        LOG.error("Failed to load PR %s/%s#%s", owner, name, pr_number)
        return
    run_full_review(
        installation_id=installation_id,
        owner=owner,
        repo=name,
        pr_number=pr_number,
        base_ref=pr_body["base"]["ref"],
        head_ref=pr_body["head"]["ref"],
        head_sha=pr_body["head"]["sha"],
        clone_url=repo.get("clone_url")
        or f"https://github.com/{owner}/{name}.git",
    )


def process_event(event: str, payload: dict[str, Any]) -> None:
    if event == "pull_request":
        handle_pull_request(payload)
    elif event in ("issue_comment", "pull_request_review_comment"):
        # issue_comment on PRs has issue.pull_request
        if event == "issue_comment" and payload.get("action") not in ("created",):
            return
        if event == "pull_request_review_comment" and payload.get("action") not in (
            "created",
        ):
            return
        handle_mention(payload, event=event)
    else:
        LOG.info("Ignoring event type %s", event)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: Any) -> None:
        LOG.info("%s - %s", self.address_string(), fmt % args)

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/healthz", "/health", "/"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":true,"provider":"github"}')
            return
        self.send_error(404)

    def do_POST(self) -> None:  # noqa: N802
        if self.path.rstrip("/") != "/hooks/github":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        sig = self.headers.get("X-Hub-Signature-256")
        if not verify_signature(raw, sig):
            self.send_error(401, "invalid signature")
            return
        try:
            payload = json.loads(raw.decode())
        except json.JSONDecodeError:
            self.send_error(400, "invalid json")
            return
        event = self.headers.get("X-GitHub-Event") or ""
        self.send_response(202)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"accepted":true}')
        threading.Thread(
            target=process_event, args=(event, payload), daemon=True
        ).start()


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    if not GITHUB_APP_ID or not _load_private_key():
        LOG.warning("GitHub App credentials incomplete — token minting will fail")
    if not GITHUB_WEBHOOK_SECRET:
        LOG.warning("GITHUB_WEBHOOK_SECRET empty — all webhooks rejected")
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    LOG.info(
        "Listening on %s:%s (github app id=%s bot=@%s agent=%s)",
        LISTEN_HOST,
        LISTEN_PORT,
        GITHUB_APP_ID or "?",
        GITHUB_BOT_SLUG,
        AGENT_URL,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
