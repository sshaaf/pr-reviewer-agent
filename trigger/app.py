#!/usr/bin/env python3
"""GitLab MR webhook trigger (auto-review + @mention; named bot; read-only)."""

from __future__ import annotations

import hmac
import json
import logging
import os
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from base64 import b64encode
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from mention_intents import (
    FIX_REFUSE_MESSAGE,
    has_mention,
    parse_intent,
    strip_mention,
)

LOG = logging.getLogger("gitlab-trigger")

GITLAB_WEBHOOK_SECRET = os.environ.get("GITLAB_WEBHOOK_SECRET", "")
GITLAB_TOKEN = os.environ.get("GITLAB_TOKEN", "")
GITLAB_URL = os.environ.get("GITLAB_URL", "http://gitlab-webservice-default.gitlab.svc:8181").rstrip("/")
GITLAB_BOT_USERNAME = os.environ.get("GITLAB_BOT_USERNAME", "").lstrip("@")
AGENT_URL = os.environ.get("AGENT_URL", "http://127.0.0.1:4096").rstrip("/")
OPENCODE_USER = os.environ.get("OPENCODE_SERVER_USER", "opencode")
OPENCODE_PASSWORD = os.environ.get("OPENCODE_SERVER_PASSWORD", "")
WORKSPACE = os.environ.get("WORKSPACE", "/workspace/repo")
REVIEW_SCRIPT = os.environ.get(
    "REVIEW_WORKSPACE_SCRIPT", "/app/scripts/review-workspace.sh"
)
LISTEN_HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8080"))
LOCK = threading.Lock()
RECENT: dict[str, float] = {}
DEBOUNCE_SECONDS = int(os.environ.get("DEBOUNCE_SECONDS", "60"))

# Resolved once at startup (env or /user).
_BOT_USERNAME = ""


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


def gitlab_api(
    method: str,
    path: str,
    body: dict[str, Any] | None = None,
    timeout: int = 60,
) -> tuple[int, Any]:
    url = f"{GITLAB_URL}/api/v4{path}"
    headers = {"PRIVATE-TOKEN": GITLAB_TOKEN}
    return _http_json(method, url, body=body, headers=headers, timeout=timeout)


def resolve_bot_username() -> str:
    """Return bot username from env or GitLab /user for the configured token."""
    global _BOT_USERNAME
    if _BOT_USERNAME:
        return _BOT_USERNAME
    if GITLAB_BOT_USERNAME:
        _BOT_USERNAME = GITLAB_BOT_USERNAME.lstrip("@")
        return _BOT_USERNAME
    if not GITLAB_TOKEN:
        return ""
    try:
        code, user = gitlab_api("GET", "/user")
        if code == 200 and isinstance(user, dict):
            _BOT_USERNAME = (user.get("username") or "").lstrip("@")
            return _BOT_USERNAME
    except Exception:
        LOG.warning("Could not resolve bot username via /user", exc_info=True)
    return ""


def validate_webhook_token(header_token: str | None) -> bool:
    if not GITLAB_WEBHOOK_SECRET:
        LOG.warning("GITLAB_WEBHOOK_SECRET unset — rejecting all webhooks")
        return False
    if not header_token:
        return False
    return hmac.compare_digest(header_token, GITLAB_WEBHOOK_SECRET)


def is_wip_or_draft(attrs: dict[str, Any]) -> bool:
    if attrs.get("work_in_progress") is True:
        return True
    if attrs.get("draft") is True:
        return True
    return False


def should_handle_mr(payload: dict[str, Any]) -> tuple[bool, str]:
    """Auto-review gate for merge_request events (not Note mentions)."""
    if payload.get("object_kind") != "merge_request":
        return False, "not merge_request"
    attrs = payload.get("object_attributes") or {}
    action = attrs.get("action") or ""
    state = attrs.get("state") or ""
    if state not in ("opened", "reopened") and action not in (
        "open",
        "reopen",
        "update",
    ):
        return False, f"skip action={action} state={state}"
    if is_wip_or_draft(attrs):
        return False, "wip_or_draft"
    # Ignore non-code updates when possible
    if action == "update" and attrs.get("oldrev") is None:
        if not attrs.get("last_commit"):
            return False, "update without commit"
    return True, "ok"


def debounce_key(project_id: int, iid: int, sha: str) -> str:
    return f"{project_id}:{iid}:{sha}"


def prepare_workspace_from_mr(
    *,
    project: dict[str, Any],
    mr: dict[str, Any],
) -> dict[str, str]:
    repo_url = (
        project.get("http_url_to_repo")
        or project.get("git_http_url")
        or os.environ.get("REPO_URL", "")
    )
    target = mr.get("target_branch") or "main"
    source = mr.get("source_branch") or ""
    last = mr.get("last_commit") or {}
    head_sha = last.get("id") or ""

    env = os.environ.copy()
    env.update(
        {
            "REPO_URL": repo_url,
            "GITLAB_TOKEN": GITLAB_TOKEN,
            "TARGET_BRANCH": target,
            "SOURCE_BRANCH": source,
            "HEAD_SHA": head_sha,
            "WORKSPACE": WORKSPACE,
        }
    )
    LOG.info("Running %s for %s", REVIEW_SCRIPT, repo_url)
    subprocess.run([REVIEW_SCRIPT], check=True, env=env)
    meta_dir = Path(WORKSPACE).parent
    base_ref = (meta_dir / "base_ref").read_text().strip()
    head_ref = (meta_dir / "head_ref").read_text().strip()
    return {
        "repo_url": repo_url,
        "base_ref": base_ref,
        "head_ref": head_ref,
        "project_id": str(mr.get("target_project_id") or project.get("id") or ""),
        "pr_number": str(mr.get("iid") or ""),
    }


def prepare_workspace(payload: dict[str, Any]) -> dict[str, str]:
    attrs = payload["object_attributes"]
    project = payload.get("project") or {}
    return prepare_workspace_from_mr(project=project, mr=attrs)


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


def load_repo_policy_json(workspace: str) -> str | None:
    """Return policy file contents from conventional repo paths, or None."""
    root = Path(workspace)
    for rel in (".rgctl/policy.json", "policy.json"):
        path = root / rel
        if path.is_file():
            try:
                text = path.read_text(encoding="utf-8")
                json.loads(text)  # validate
                LOG.info("Loaded repo policy from %s", path)
                return text
            except (OSError, json.JSONDecodeError) as e:
                LOG.warning("Ignoring invalid policy at %s: %s", path, e)
    return None


def invoke_skill(meta: dict[str, str]) -> None:
    headers = {"Authorization": _basic_auth_header()}
    wait_agent_healthy()
    _, session = _http_json("POST", f"{AGENT_URL}/session", body={}, headers=headers)
    session_id = (session or {}).get("id") or ((session or {}).get("session") or {}).get(
        "id"
    )
    if not session_id:
        raise RuntimeError(f"no session id: {session}")

    input_json: dict[str, Any] = {
        "repo_url": meta["repo_url"],
        "pr_number": int(meta["pr_number"]),
        "project_id": int(meta["project_id"]) if meta["project_id"].isdigit() else meta["project_id"],
        "base_ref": meta["base_ref"],
        "head_ref": meta["head_ref"],
        "github_token": None,
        "gitlab_token": GITLAB_TOKEN,
        "gitlab_url": GITLAB_URL,
        "policy_json": None,
        "config": {
            "upstream_depth": int(os.environ.get("REVIEW_UPSTREAM_DEPTH", "2")),
            "downstream_depth": int(os.environ.get("REVIEW_DOWNSTREAM_DEPTH", "1")),
            "fanout": int(os.environ.get("REVIEW_FANOUT", "5")),
            "max_symbols": int(os.environ.get("REVIEW_MAX_SYMBOLS", "25")),
            "output_mode": "comment",
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
Post to GitLab (output_mode comment) with this note shape:
  1) Top: ## Verdict: <emoji> GREEN|YELLOW|RED — one sentence (ladder in the skill)
  2) Sections 1–4 as usual
  3) End: ## Guidelines with Concerns / Blockers / Open questions / What's fine
Also post §3/§4 line findings as inline Changes-tab comments (optional severity green|yellow|red):
  write .rgctl/line-comments.json then run
  bash /app/scripts/post-inline-comments.sh .rgctl/line-comments.json
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
    LOG.info(
        "prompt_async accepted session=%s project=%s mr=%s",
        session_id,
        meta["project_id"],
        meta["pr_number"],
    )


def post_mr_note(project_id: int | str, mr_iid: int, body: str) -> None:
    pid = urllib.parse.quote(str(project_id), safe="")
    gitlab_api(
        "POST",
        f"/projects/{pid}/merge_requests/{int(mr_iid)}/notes",
        body={"body": body},
    )


def run_full_review(
    *,
    project: dict[str, Any],
    mr: dict[str, Any],
) -> None:
    project_id = int(mr.get("target_project_id") or project.get("id") or 0)
    iid = int(mr.get("iid") or 0)
    sha = ((mr.get("last_commit") or {}).get("id")) or ""
    key = debounce_key(project_id, iid, sha)
    now = time.time()
    if key in RECENT and now - RECENT[key] < DEBOUNCE_SECONDS:
        LOG.info("Debounced %s", key)
        return
    RECENT[key] = now

    if not LOCK.acquire(blocking=False):
        LOG.warning("Review already in progress; skipping %s", key)
        return
    try:
        meta = prepare_workspace_from_mr(project=project, mr=mr)
        os.environ["REPO_PATH"] = WORKSPACE
        invoke_skill(meta)
    except Exception:
        LOG.exception("Review failed for %s", key)
    finally:
        LOCK.release()


def handle_note(payload: dict[str, Any]) -> None:
    """Route @bot mentions on MR notes (WIP override for explicit review)."""
    note = payload.get("object_attributes") or {}
    if (note.get("noteable_type") or "") != "MergeRequest":
        LOG.info("Ignoring note: not on MergeRequest")
        return
    mr = payload.get("merge_request")
    if not isinstance(mr, dict) or not mr.get("iid"):
        LOG.info("Ignoring note: no merge_request context")
        return

    bot = resolve_bot_username()
    author = ((payload.get("user") or {}).get("username") or "").lstrip("@")
    if bot and author and author.lower() == bot.lower():
        LOG.info("Ignoring bot self-note")
        return

    body = note.get("note") or note.get("body") or ""
    if not bot or not has_mention(body, bot):
        return

    intent = parse_intent(body, bot)
    LOG.info("Mention intent=%s mr=%s", intent, mr.get("iid"))
    project = payload.get("project") or {}
    project_id = mr.get("target_project_id") or project.get("id")
    iid = int(mr["iid"])

    if intent == "fix_refuse":
        msg = FIX_REFUSE_MESSAGE.replace("@BOT", f"@{bot}")
        if project_id:
            post_mr_note(project_id, iid, msg)
        return

    if intent == "explain":
        q = strip_mention(body, bot)
        reply = (
            f"_(Explain mode — read-only.)_ I received: {q[:500]}\n\n"
            f"For a full rgctl impact review, comment `@{bot} review`. "
            "I cannot open fix MRs in this mode."
        )
        if project_id:
            post_mr_note(project_id, iid, reply)
        return

    # review (including default @bot) — overrides WIP/draft skip
    run_full_review(project=project, mr=mr)


def process_merge_request(payload: dict[str, Any]) -> None:
    ok, reason = should_handle_mr(payload)
    if not ok:
        LOG.info("Ignoring merge_request: %s", reason)
        return
    attrs = payload["object_attributes"]
    project = payload.get("project") or {}
    run_full_review(project=project, mr=attrs)


def process_webhook(payload: dict[str, Any]) -> None:
    kind = payload.get("object_kind") or ""
    if kind == "merge_request":
        process_merge_request(payload)
    elif kind == "note":
        handle_note(payload)
    else:
        LOG.info("Ignoring event type %s", kind)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: Any) -> None:
        LOG.info("%s - %s", self.address_string(), fmt % args)

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/healthz", "/health", "/"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
            return
        self.send_error(404)

    def do_POST(self) -> None:  # noqa: N802
        if self.path.rstrip("/") != "/hooks/gitlab":
            self.send_error(404)
            return
        token = self.headers.get("X-Gitlab-Token")
        if not validate_webhook_token(token):
            self.send_error(401, "invalid webhook token")
            return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode())
        except json.JSONDecodeError:
            self.send_error(400, "invalid json")
            return
        self.send_response(202)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"accepted":true}')
        threading.Thread(target=process_webhook, args=(payload,), daemon=True).start()


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    if not GITLAB_TOKEN:
        LOG.warning("GITLAB_TOKEN is empty — clone and MR notes will fail")
    bot = resolve_bot_username()
    if not bot:
        LOG.warning(
            "GITLAB_BOT_USERNAME unset and /user unresolved — @mentions will not match"
        )
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    LOG.info(
        "Listening on %s:%s (agent=%s gitlab=%s bot=@%s)",
        LISTEN_HOST,
        LISTEN_PORT,
        AGENT_URL,
        GITLAB_URL,
        bot or "?",
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
