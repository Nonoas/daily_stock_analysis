# -*- coding: utf-8 -*-
"""GitHub OAuth authentication, whitelist authorization and signed local sessions."""

from __future__ import annotations

import base64
from dataclasses import dataclass
from functools import lru_cache
import hashlib
import hmac
import json
import logging
import os
from pathlib import Path
import re
import secrets
import sys
import tempfile
import threading
import time
from typing import Optional
from urllib.parse import unquote, urlsplit

from dotenv import dotenv_values

logger = logging.getLogger(__name__)

COOKIE_NAME = "dsa_session"
OAUTH_COOKIE_NAME = "dsa_github_oauth"
OAUTH_STATE_MAX_AGE = 600
SESSION_MAX_AGE_HOURS_DEFAULT = 24
RATE_LIMIT_WINDOW_SEC = 300
RATE_LIMIT_MAX_FAILURES = 5
GITHUB_CONFIG_KEYS = (
    "GITHUB_OAUTH_CLIENT_ID",
    "GITHUB_OAUTH_CLIENT_SECRET",
    "GITHUB_OAUTH_CALLBACK_URL",
    "GITHUB_ALLOWED_USERS",
)
GITHUB_SERVER_CONFIG_KEYS = (*GITHUB_CONFIG_KEYS, "GITHUB_OAUTH_ALLOW_HTTP")
GITHUB_CALLBACK_PATH = "/api/v1/auth/github/callback"
_LOGIN_PATTERN = re.compile(r"[a-z\d](?:[a-z\d-]{0,37}[a-z\d])?", re.IGNORECASE | re.ASCII)
_rate_limit: dict[str, tuple[int, float]] = {}
_rate_limit_lock = threading.Lock()


@lru_cache(maxsize=4)
def _read_auth_env(path: str, modified_ns: int, size: int) -> dict:
    """Cache file parsing by metadata; process environment overrides are never cached."""
    return dotenv_values(path, interpolate=False)


def _auth_values() -> dict[str, str]:
    """Honor injected process variables first, then the active runtime env file."""
    path = Path(os.getenv("ENV_FILE") or Path(__file__).resolve().parent.parent / ".env")
    if path.is_file():
        metadata = path.stat()
        values = _read_auth_env(str(path), metadata.st_mtime_ns, metadata.st_size)
    else:
        values = {}
    keys = (*GITHUB_SERVER_CONFIG_KEYS, "ADMIN_AUTH_ENABLED", "ADMIN_SESSION_MAX_AGE_HOURS", "DATABASE_PATH")
    return {key: os.environ.get(key, values.get(key) or "") for key in keys}


@dataclass(frozen=True)
class GitHubAuthConfig:
    client_id: str
    client_secret: str
    callback_url: str
    allowed_users: frozenset[str]
    valid_allowlist: bool
    allow_http: bool = True

    @property
    def configured(self) -> bool:
        try:
            callback = urlsplit(self.callback_url)
            valid_url = (
                callback.path == GITHUB_CALLBACK_PATH
                and not callback.query and not callback.fragment and callback.username is None
                and bool(callback.hostname)
                and (callback.scheme == "https" or (callback.scheme == "http" and self.allow_http))
            )
            # Accessing port also rejects malformed port declarations.
            callback.port
        except ValueError:
            return False
        return bool(self.client_id and self.client_secret and valid_url
                    and self.allowed_users and self.valid_allowlist)


def get_github_auth_config() -> GitHubAuthConfig:
    values = _auth_values()
    users = frozenset(value.strip().lower() for value in values["GITHUB_ALLOWED_USERS"].split(",") if value.strip())
    return GitHubAuthConfig(
        client_id=values["GITHUB_OAUTH_CLIENT_ID"].strip(),
        client_secret=values["GITHUB_OAUTH_CLIENT_SECRET"].strip(),
        callback_url=values["GITHUB_OAUTH_CALLBACK_URL"].strip(),
        allowed_users=users,
        valid_allowlist=all(_LOGIN_PATTERN.fullmatch(user) and "--" not in user for user in users),
        # Missing/empty preserves the HTTP-enabled default; invalid values deny HTTP.
        allow_http=values["GITHUB_OAUTH_ALLOW_HTTP"].strip().lower() in {"", "true", "1", "yes", "on"},
    )


def is_auth_enabled() -> bool:
    """GitHub identity settings enable protection; the HTTP policy alone does not."""
    values = _auth_values()
    return values["ADMIN_AUTH_ENABLED"].strip().lower() in {"true", "1", "yes"} or any(
        values[key].strip() for key in GITHUB_CONFIG_KEYS
    )


def refresh_auth_state() -> None:
    """Invalidate parsed file data; signing secrets are always read from disk across workers."""
    _read_auth_env.cache_clear()


def _get_data_dir() -> Path:
    return Path(_auth_values()["DATABASE_PATH"] or "./data/stock_analysis.db").resolve().parent


def _load_session_secret(create: bool = False) -> Optional[bytes]:
    path = _get_data_dir() / ".session_secret"
    try:
        if not path.exists() and create:
            path.parent.mkdir(parents=True, exist_ok=True)
            try:
                descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                pass
            else:
                with os.fdopen(descriptor, "wb") as output:
                    output.write(secrets.token_bytes(32))
        if not path.exists():
            return None
        value = path.read_bytes()
        if len(value) != 32:
            logger.error("Invalid session signing secret; authentication remains blocked")
            return None
        return value
    except OSError:
        logger.error("Cannot access session signing secret; authentication remains blocked")
        return None


def rotate_session_secret() -> bool:
    """Invalidate all sessions across workers, retaining the existing logout contract."""
    directory = _get_data_dir()
    temporary = None
    try:
        directory.mkdir(parents=True, exist_ok=True)
        descriptor, name = tempfile.mkstemp(prefix=".session-secret-", dir=directory)
        temporary = Path(name)
        with os.fdopen(descriptor, "wb") as output:
            output.write(secrets.token_bytes(32))
        temporary.replace(directory / ".session_secret")
        return True
    except OSError:
        logger.error("Failed to rotate session signing secret")
        return False
    finally:
        if temporary and temporary.exists():
            temporary.unlink()


def session_max_age() -> int:
    try:
        hours = int(_auth_values()["ADMIN_SESSION_MAX_AGE_HOURS"] or SESSION_MAX_AGE_HOURS_DEFAULT)
    except ValueError:
        hours = SESSION_MAX_AGE_HOURS_DEFAULT
    return (hours if hours > 0 else SESSION_MAX_AGE_HOURS_DEFAULT) * 3600


def _sign(payload: dict, purpose: str) -> str:
    secret = _load_session_secret(create=True)
    if not secret:
        return ""
    encoded = base64.urlsafe_b64encode(
        json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    ).decode("ascii").rstrip("=")
    signature = hmac.new(secret, (purpose + "." + encoded).encode("ascii"), hashlib.sha256).hexdigest()
    return encoded + "." + signature


def _verify(value: str, purpose: str, max_age: int) -> Optional[dict]:
    if not value or len(value) > 3800 or value.count(".") != 1:
        return None
    secret = _load_session_secret()
    if not secret:
        return None
    encoded, signature = value.split(".")
    if not encoded.isascii() or not signature.isascii():
        return None
    try:
        expected = hmac.new(secret, (purpose + "." + encoded).encode("ascii"), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature, expected):
            return None
        payload = json.loads(base64.b64decode(encoded + "=" * (-len(encoded) % 4), altchars=b"-_", validate=True))
        if not isinstance(payload, dict) or type(payload.get("iat")) is not int:
            return None
        age = time.time() - payload["iat"]
        if age < -30 or age > max_age:
            return None
        return payload
    except (ValueError, UnicodeError):
        return None


def create_session(user: dict | None = None) -> str:
    """Issue identity-bearing GitHub sessions only; legacy password tokens cannot be created."""
    config = get_github_auth_config()
    if not is_auth_enabled() or not config.configured or not user:
        return ""
    if str(user.get("login", "")).lower() not in config.allowed_users:
        return ""
    return _sign({
        "v": 2, "iat": int(time.time()), "nonce": secrets.token_urlsafe(24),
        "client": config.client_id, "user": user,
    }, "github-session")


def get_session_user(value: str | None) -> Optional[dict]:
    config = get_github_auth_config()
    if not is_auth_enabled() or not config.configured:
        return None
    payload = _verify(value or "", "github-session", session_max_age())
    if not payload or payload.get("v") != 2 or payload.get("client") != config.client_id:
        return None
    user = payload.get("user")
    if not isinstance(user, dict) or str(user.get("login", "")).lower() not in config.allowed_users:
        return None
    return user


def verify_session(value: str) -> bool:
    return get_session_user(value) is not None


def safe_login_redirect(value: str | None) -> str:
    value = value or "/"
    if (len(value) > 2048 or not value.startswith("/") or value.startswith("//")
            or "\\" in value or any(ord(char) < 32 or ord(char) == 127 for char in value)):
        return "/"
    decoded_path = unquote(urlsplit(value).path)
    if decoded_path.startswith("//") or "\\" in decoded_path or any(ord(char) < 32 for char in decoded_path):
        return "/"
    return value


def create_oauth_state(redirect: str) -> tuple[str, str, str]:
    state, verifier = secrets.token_urlsafe(32), secrets.token_urlsafe(48)
    cookie = _sign({
        "iat": int(time.time()), "state": state, "verifier": verifier,
        "redirect": safe_login_redirect(redirect),
        "client": get_github_auth_config().client_id,
    }, "github-oauth-state")
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).decode("ascii").rstrip("=")
    return state, cookie, challenge


def verify_oauth_state(cookie: str, state: str) -> Optional[dict]:
    payload = _verify(cookie, "github-oauth-state", OAUTH_STATE_MAX_AGE)
    if (not payload or payload.get("client") != get_github_auth_config().client_id
            or not isinstance(payload.get("state"), str) or not isinstance(payload.get("verifier"), str)):
        return None
    if not state or not state.isascii() or not hmac.compare_digest(payload["state"], state):
        return None
    return payload


def _get_lock():
    return _rate_limit_lock


def get_client_ip(request) -> str:
    """Get client IP, respecting TRUST_X_FORWARDED_FOR.

    When behind a single trusted reverse proxy, the proxy appends the real
    client IP as the rightmost entry in X-Forwarded-For.  We use [-1] instead
    of [0] so that an attacker cannot spoof an arbitrary leftmost value to
    rotate rate-limit buckets and bypass brute-force protection.
    """
    if os.getenv("TRUST_X_FORWARDED_FOR", "false").lower() == "true":
        forwarded = request.headers.get("X-Forwarded-For")
        if forwarded:
            return forwarded.split(",")[-1].strip()
    if request.client:
        return request.client.host or "127.0.0.1"
    return "127.0.0.1"


def check_rate_limit(ip: str) -> bool:
    """Return True if under limit, False if rate limited."""
    lock = _get_lock()
    now = time.time()
    with lock:
        expired_keys = [k for k, (_, ts) in _rate_limit.items() if now - ts > RATE_LIMIT_WINDOW_SEC]
        for k in expired_keys:
            del _rate_limit[k]
        if ip in _rate_limit:
            count, first_ts = _rate_limit[ip]
            if count >= RATE_LIMIT_MAX_FAILURES:
                return False
        return True


def record_login_failure(ip: str) -> None:
    """Record a failed login attempt for rate limiting."""
    lock = _get_lock()
    now = time.time()
    with lock:
        if ip in _rate_limit:
            count, first_ts = _rate_limit[ip]
            if now - first_ts > RATE_LIMIT_WINDOW_SEC:
                _rate_limit[ip] = (1, now)
            else:
                _rate_limit[ip] = (count + 1, first_ts)
        else:
            _rate_limit[ip] = (1, now)


def clear_rate_limit(ip: str) -> None:
    """Clear rate limit for IP after successful login."""
    lock = _get_lock()
    with lock:
        _rate_limit.pop(ip, None)


def _main() -> int:
    print("Password authentication has been replaced by GitHub OAuth. Configure GITHUB_OAUTH_* and GITHUB_ALLOWED_USERS.",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_main())
