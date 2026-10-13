"""GitHub App JWT + installation access token (stdlib + openssl)."""

from __future__ import annotations

import base64
import json
import logging
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from typing import Any

LOG = logging.getLogger("github-auth")

GITHUB_API = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def make_app_jwt(app_id: str, private_key_pem: str, now: int | None = None) -> str:
    """RS256 JWT for GitHub App authentication (max 10 minutes)."""
    now = int(time.time() if now is None else now)
    header = {"alg": "RS256", "typ": "JWT"}
    payload = {"iat": now - 60, "exp": now + 9 * 60, "iss": str(app_id)}
    signing_input = (
        f"{_b64url(json.dumps(header, separators=(',', ':')).encode())}."
        f"{_b64url(json.dumps(payload, separators=(',', ':')).encode())}"
    ).encode("ascii")

    with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as kf:
        kf.write(private_key_pem)
        if not private_key_pem.endswith("\n"):
            kf.write("\n")
        key_path = kf.name
    try:
        proc = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_path],
            input=signing_input,
            capture_output=True,
            check=True,
        )
    except FileNotFoundError as e:
        raise RuntimeError("openssl required to sign GitHub App JWT") from e
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"openssl sign failed: {e.stderr.decode(errors='replace')}") from e
    finally:
        try:
            os.unlink(key_path)
        except OSError:
            pass

    return f"{signing_input.decode('ascii')}.{_b64url(proc.stdout)}"


def _http_json(
    method: str,
    url: str,
    headers: dict[str, str] | None = None,
    body: dict[str, Any] | None = None,
    timeout: int = 60,
) -> tuple[int, Any]:
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if body is not None:
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
        err = e.read().decode(errors="replace")
        LOG.error("HTTP %s %s → %s %s", method, url, e.code, err[:500])
        raise


def installation_token(app_id: str, private_key_pem: str, installation_id: int) -> str:
    jwt = make_app_jwt(app_id, private_key_pem)
    code, body = _http_json(
        "POST",
        f"{GITHUB_API}/app/installations/{installation_id}/access_tokens",
        headers={"Authorization": f"Bearer {jwt}"},
        body={},
    )
    if code not in (200, 201) or not isinstance(body, dict) or not body.get("token"):
        raise RuntimeError(f"installation token failed HTTP {code}: {body}")
    return str(body["token"])


def github_api(
    method: str,
    path: str,
    token: str,
    body: dict[str, Any] | None = None,
) -> tuple[int, Any]:
    url = path if path.startswith("http") else f"{GITHUB_API}{path}"
    return _http_json(
        method,
        url,
        headers={"Authorization": f"Bearer {token}"},
        body=body,
    )
