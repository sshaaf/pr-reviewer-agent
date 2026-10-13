#!/usr/bin/env python3
"""GitLab MR webhook trigger for OpenShift pr-reviewer-agent (sidecar-friendly)."""

from __future__ import annotations

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

LOG = logging.getLogger("gitlab-trigger")

GITLAB_WEBHOOK_SECRET = os.environ.get("GITLAB_WEBHOOK_SECRET", "")
GITLAB_TOKEN = os.environ.get("GITLAB_TOKEN", "")
GITLAB_URL = os.environ.get("GITLAB_URL", "http://gitlab-webservice-default.gitlab.svc:8181").rstrip("/")
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


def validate_webhook_token(header_token: str | None) -> bool:
    if not GITLAB_WEBHOOK_SECRET:
        LOG.warning("GITLAB_WEBHOOK_SECRET unset — rejecting all webhooks")
        return False
    if not header_token:
        return False
    return hmac.compare_digest(header_token, GITLAB_WEBHOOK_SECRET)


def should_handle_mr(payload: dict[str, Any]) -> tuple[bool, str]:
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
    # Ignore non-code updates when possible
    if action == "update" and attrs.get("oldrev") is None:
        # May still be a push; allow if last_commit present
        if not attrs.get("last_commit"):
            return False, "update without commit"
    return True, "ok"


def debounce_key(project_id: int, iid: int, sha: str) -> str:
    return f"{project_id}:{iid}:{sha}"


def prepare_workspace(payload: dict[str, Any]) -> dict[str, str]:
    attrs = payload["object_attributes"]
    project = payload.get("project") or {}
    repo_url = (
        project.get("http_url_to_repo")
        or project.get("git_http_url")
        or os.environ.get("REPO_URL", "")
    )
    target = attrs.get("target_branch") or "main"
    source = attrs.get("source_branch") or ""
    last = attrs.get("last_commit") or {}
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
        "project_id": str(attrs.get("target_project_id") or project.get("id") or ""),
        "pr_number": str(attrs.get("iid") or ""),
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


def invoke_skill(meta: dict[str, str]) -> None:
    headers = {"Authorization": _basic_auth_header()}
    wait_agent_healthy()
    _, session = _http_json("POST", f"{AGENT_URL}/session", body={}, headers=headers)
    session_id = (session or {}).get("id") or ((session or {}).get("session") or {}).get(
        "id"
    )
    if not session_id:
        raise RuntimeError(f"no session id: {session}")

    input_json = {
        "repo_url": meta["repo_url"],
        "pr_number": int(meta["pr_number"]),
        "project_id": int(meta["project_id"]) if meta["project_id"].isdigit() else meta["project_id"],
        "base_ref": meta["base_ref"],
        "head_ref": meta["head_ref"],
        "github_token": None,
        "gitlab_token": GITLAB_TOKEN,
        "gitlab_url": GITLAB_URL,
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

    limits = os.environ.get("RGCTL_WITH_LIMITS", "max-mem-mb=1536,threads=1")
    prompt = f"""Load skill rgctl-pr-reviewer-v2 and execute it.
Repository root is {WORKSPACE} (REPO_PATH). Run all git and rgctl commands there.
Every `rgctl discover` MUST use --with-limits (RGCTL_WITH_LIMITS={limits}; keys max-mem-mb + threads).
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
    LOG.info("prompt_async accepted session=%s project=%s mr=%s", session_id, meta["project_id"], meta["pr_number"])


def process_webhook(payload: dict[str, Any]) -> None:
    ok, reason = should_handle_mr(payload)
    if not ok:
        LOG.info("Ignoring event: %s", reason)
        return
    attrs = payload["object_attributes"]
    project = payload.get("project") or {}
    project_id = int(attrs.get("target_project_id") or project.get("id") or 0)
    iid = int(attrs.get("iid") or 0)
    sha = ((attrs.get("last_commit") or {}).get("id")) or ""
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
        meta = prepare_workspace(payload)
        # Point agent at prepared workspace for this review
        os.environ["REPO_PATH"] = WORKSPACE
        invoke_skill(meta)
    except Exception:
        LOG.exception("Review failed for %s", key)
    finally:
        LOCK.release()


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
        # Ack quickly; process in background
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
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    LOG.info(
        "Listening on %s:%s (agent=%s gitlab=%s)",
        LISTEN_HOST,
        LISTEN_PORT,
        AGENT_URL,
        GITLAB_URL,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
