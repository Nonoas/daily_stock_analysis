# -*- coding: utf-8 -*-
"""GitHub OAuth login and whitelist-protected admin sessions."""

from __future__ import annotations

import logging
from urllib.parse import urlencode, urlsplit

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, RedirectResponse, Response
import httpx

from src.auth import (
    COOKIE_NAME,
    OAUTH_COOKIE_NAME,
    OAUTH_STATE_MAX_AGE,
    check_rate_limit,
    clear_rate_limit,
    create_oauth_state,
    create_session,
    get_client_ip,
    get_github_auth_config,
    get_session_user,
    is_auth_enabled,
    record_login_failure,
    rotate_session_secret,
    safe_login_redirect,
    session_max_age,
    verify_oauth_state,
)

logger = logging.getLogger(__name__)
router = APIRouter()
_PRIVATE_HEADERS = {"Cache-Control": "no-store", "Pragma": "no-cache", "Referrer-Policy": "no-referrer"}


class GitHubOAuthError(Exception):
    """Public error code only; tokens and provider response bodies must never be logged."""


def _log_github_lookup_failure(error: Exception) -> None:
    """Log only fixed endpoint labels and HTTP metadata, never exception messages."""
    response = error.response if isinstance(error, httpx.HTTPStatusError) else None
    request = None
    if isinstance(error, httpx.HTTPError):
        try:
            request = error.request
        except RuntimeError:
            pass  # An HTTPX error constructed without a request has no endpoint metadata.
    stages = {
        ("github.com", "/login/oauth/access_token"): "token_exchange",
        ("api.github.com", "/user"): "profile",
        ("api.github.com", "/user/emails"): "emails",
    }
    stage = stages.get((request.url.host, request.url.path), "unknown") if request else "unknown"
    status = response.status_code if response is not None else None
    rate_limited = status == 429 or (
        status == 403 and response.headers.get("x-ratelimit-remaining") == "0"
    )
    logger.warning(
        "GitHub OAuth identity lookup failed: stage=%s error=%s status=%s rate_limited=%s",
        stage, type(error).__name__, status, rate_limited,
    )


def _cookie_params(request: Request) -> dict:
    callback = get_github_auth_config().callback_url
    try:
        callback_https = urlsplit(callback).scheme == "https"
    except ValueError:
        callback_https = False
    secure = callback_https or request.url.scheme == "https"
    return {"httponly": True, "samesite": "lax", "secure": secure, "path": "/", "max_age": session_max_age()}


def _set_session_cookie(response: Response, session_value: str, request: Request) -> None:
    response.set_cookie(key=COOKIE_NAME, value=session_value, **_cookie_params(request))


def _get_auth_status_dict(request: Request | None = None) -> dict:
    enabled = is_auth_enabled()
    user = get_session_user(request.cookies.get(COOKIE_NAME)) if enabled and request else None
    return {
        "authEnabled": enabled,
        "loggedIn": user is not None,
        "provider": "github",
        "oauthConfigured": get_github_auth_config().configured,
        "user": user,
        # Retained response fields let old clients render a safe, non-password state.
        "passwordSet": False,
        "passwordChangeable": False,
        "setupState": "enabled" if enabled else "no_password",
    }


def _login_error(request: Request, error: str, redirect: str = "/") -> RedirectResponse:
    response = RedirectResponse(
        "/login?" + urlencode({"oauthError": error, "redirect": safe_login_redirect(redirect)}),
        status_code=303, headers=_PRIVATE_HEADERS,
    )
    params = _cookie_params(request)
    for cookie in (OAUTH_COOKIE_NAME, COOKIE_NAME):
        response.delete_cookie(cookie, path="/", secure=params["secure"], httponly=True, samesite="lax")
    return response


@router.get("/status", summary="Get GitHub authentication status")
async def auth_status(request: Request):
    return JSONResponse(_get_auth_status_dict(request), headers=_PRIVATE_HEADERS)


@router.get("/github/login", summary="Start GitHub OAuth login")
async def github_login(request: Request, redirect: str = "/"):
    config = get_github_auth_config()
    if not is_auth_enabled() or not config.configured:
        return JSONResponse(
            status_code=503,
            content={"error": "github_not_configured", "message": "GitHub OAuth and a nonempty whitelist must be configured"},
            headers=_PRIVATE_HEADERS,
        )
    if not check_rate_limit(get_client_ip(request)):
        return _login_error(request, "rate_limited", redirect)
    state, cookie, challenge = create_oauth_state(redirect)
    if not cookie:
        return JSONResponse(
            status_code=503, content={"error": "session_unavailable", "message": "Cannot create a secure login session"},
            headers=_PRIVATE_HEADERS,
        )
    url = "https://github.com/login/oauth/authorize?" + urlencode({
        "client_id": config.client_id,
        "redirect_uri": config.callback_url,
        "scope": "read:user user:email",
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    })
    response = RedirectResponse(url, status_code=303, headers=_PRIVATE_HEADERS)
    params = _cookie_params(request)
    params["max_age"] = OAUTH_STATE_MAX_AGE
    response.set_cookie(OAUTH_COOKIE_NAME, cookie, **params)
    return response


async def _github_user(code: str, verifier: str) -> dict:
    config = get_github_auth_config()
    async with httpx.AsyncClient(timeout=httpx.Timeout(10, connect=5), follow_redirects=False) as client:
        token_response = await client.post(
            "https://github.com/login/oauth/access_token",
            headers={"Accept": "application/json"},
            data={
                "client_id": config.client_id,
                "client_secret": config.client_secret,
                "redirect_uri": config.callback_url,
                "code": code,
                "code_verifier": verifier,
            },
        )
        token_response.raise_for_status()
        token = token_response.json()
        if (not isinstance(token, dict) or not isinstance(token.get("access_token"), str)
                or not token["access_token"] or str(token.get("token_type", "")).lower() != "bearer"):
            raise GitHubOAuthError("authorization_failed")
        headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": "Bearer " + token["access_token"],
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "daily-stock-analysis",
        }
        profile_response = await client.get("https://api.github.com/user", headers=headers)
        profile_response.raise_for_status()
        profile = profile_response.json()
        if not isinstance(profile, dict) or type(profile.get("id")) is not int or profile["id"] <= 0:
            raise GitHubOAuthError("authorization_failed")
        login = profile.get("login")
        if not isinstance(login, str) or login.lower() not in config.allowed_users:
            raise GitHubOAuthError("not_allowed")
        emails_response = await client.get(
            "https://api.github.com/user/emails", headers=headers, params={"per_page": 100},
        )
        if emails_response.status_code == 403:
            raise GitHubOAuthError("email_required")
        emails_response.raise_for_status()
        emails = emails_response.json()
        if not isinstance(emails, list):
            raise GitHubOAuthError("email_required")
        verified = [
            entry for entry in emails if isinstance(entry, dict) and entry.get("verified") is True
            and isinstance(entry.get("email"), str) and entry["email"].strip()
        ]
        if not verified:
            raise GitHubOAuthError("email_required")
        email = next((entry["email"] for entry in verified if entry.get("primary") is True), verified[0]["email"])
        if len(email) > 320:
            raise GitHubOAuthError("email_required")
        avatar = profile.get("avatar_url")
        if (not isinstance(avatar, str) or len(avatar) > 512 or urlsplit(avatar).scheme != "https"
                or urlsplit(avatar).hostname != "avatars.githubusercontent.com"):
            raise GitHubOAuthError("authorization_failed")
        name = profile.get("name")
        return {
            "id": profile["id"], "login": login, "name": name[:128] if isinstance(name, str) else login,
            "avatarUrl": avatar, "email": email.strip(),
        }


@router.get("/github/callback", summary="Complete GitHub OAuth login")
async def github_callback(request: Request):
    ip = get_client_ip(request)
    if not get_github_auth_config().configured:
        return _login_error(request, "not_configured")
    if not check_rate_limit(ip):
        return _login_error(request, "rate_limited")
    state = verify_oauth_state(
        request.cookies.get(OAUTH_COOKIE_NAME, ""), request.query_params.get("state", ""),
    )
    if not state:
        record_login_failure(ip)
        return _login_error(request, "invalid_state")
    redirect = safe_login_redirect(state.get("redirect"))
    if request.query_params.get("error"):
        record_login_failure(ip)
        return _login_error(request, "denied", redirect)
    code = request.query_params.get("code", "")
    if not code or len(code) > 1024:
        record_login_failure(ip)
        return _login_error(request, "authorization_failed", redirect)
    try:
        user = await _github_user(code, state["verifier"])
    except GitHubOAuthError as exc:
        record_login_failure(ip)
        return _login_error(request, str(exc), redirect)
    except (httpx.HTTPError, ValueError) as exc:
        # Never log the token response, authorization code, secret or provider response body.
        _log_github_lookup_failure(exc)
        record_login_failure(ip)
        return _login_error(request, "unavailable", redirect)
    session = create_session(user)
    if not session:
        return _login_error(request, "session_unavailable", redirect)
    clear_rate_limit(ip)
    response = RedirectResponse(redirect, status_code=303, headers=_PRIVATE_HEADERS)
    _set_session_cookie(response, session, request)
    response.delete_cookie(OAUTH_COOKIE_NAME, path="/", secure=_cookie_params(request)["secure"],
                           httponly=True, samesite="lax")
    return response


@router.post("/login", deprecated=True)
@router.post("/settings", deprecated=True)
@router.post("/change-password", deprecated=True)
async def password_auth_removed():
    """Old clients cannot initialize passwords, disable authentication or bypass the whitelist."""
    return JSONResponse(
        status_code=410,
        content={"error": "github_auth_required", "message": "Use GitHub OAuth; manage the whitelist on the server"},
        headers=_PRIVATE_HEADERS,
    )


@router.post("/logout", summary="Log out and invalidate active sessions")
async def auth_logout(request: Request):
    if is_auth_enabled() and not rotate_session_secret():
        return JSONResponse(
            status_code=503, content={"error": "session_unavailable", "message": "Cannot invalidate session"},
            headers=_PRIVATE_HEADERS,
        )
    response = Response(status_code=204, headers=_PRIVATE_HEADERS)
    params = _cookie_params(request)
    for cookie in (COOKIE_NAME, OAUTH_COOKIE_NAME):
        response.delete_cookie(cookie, path="/", secure=params["secure"], httponly=True, samesite="lax")
    return response
