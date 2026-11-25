"""HTTP callback policy with real OAuth state, cookies and session validation."""

import base64
from dataclasses import replace
import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient
import httpx

import src.auth as auth
from api.v1.endpoints import auth as endpoint


class GitHubHttpPolicyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.env_path = Path(temporary.name) / "runtime.env"
        self.env_path.write_text("", encoding="utf-8")
        self.env = patch.dict(os.environ, {
            "ENV_FILE": str(self.env_path), "DATABASE_PATH": str(Path(temporary.name) / "test.db"),
            "GITHUB_OAUTH_CLIENT_ID": "test-client", "GITHUB_OAUTH_CLIENT_SECRET": "test-secret",
            "GITHUB_OAUTH_CALLBACK_URL": "http://dsa.example.com/api/v1/auth/github/callback",
            "GITHUB_ALLOWED_USERS": "allowed-user",
        }, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        auth.refresh_auth_state()
        auth.clear_rate_limit("testclient")
        app = FastAPI()
        app.include_router(endpoint.router, prefix="/api/v1/auth")
        self.client = TestClient(app, base_url="http://dsa.example.com", follow_redirects=False)
        self.addCleanup(self.client.close)

    def test_default_accepts_public_http_and_https(self):
        config = auth.get_github_auth_config()
        for origin in ["http://dsa.example.com", "http://192.0.2.10:8080", "http://[::1]:8080", "https://dsa.example.com"]:
            with self.subTest(origin=origin):
                self.assertTrue(replace(config, callback_url=origin + auth.GITHUB_CALLBACK_PATH).configured)

    def test_false_disables_http_including_loopback_but_keeps_https(self):
        os.environ["GITHUB_OAUTH_ALLOW_HTTP"] = "false"
        config = auth.get_github_auth_config()
        self.assertFalse(config.configured)
        self.assertFalse(replace(config, callback_url="http://127.0.0.1" + auth.GITHUB_CALLBACK_PATH).configured)
        self.assertTrue(replace(config, callback_url="https://dsa.example.com" + auth.GITHUB_CALLBACK_PATH).configured)
        self.assertEqual(self.client.get("/api/v1/auth/github/login").status_code, 503)
        self.assertFalse(self.client.get("/api/v1/auth/status").json()["oauthConfigured"])

    def test_file_policy_and_process_override(self):
        self.env_path.write_text("GITHUB_OAUTH_ALLOW_HTTP=false\n", encoding="utf-8")
        self.assertFalse(auth.get_github_auth_config().allow_http)
        for value in ["true", "1", "yes", "on", ""]:
            os.environ["GITHUB_OAUTH_ALLOW_HTTP"] = value
            self.assertTrue(auth.get_github_auth_config().allow_http)
        for value in ["false", "0", "no", "off", "typo"]:
            os.environ["GITHUB_OAUTH_ALLOW_HTTP"] = value
            self.assertFalse(auth.get_github_auth_config().allow_http)

    def test_policy_flag_alone_does_not_enable_auth(self):
        for key in auth.GITHUB_CONFIG_KEYS:
            os.environ.pop(key, None)
        os.environ["GITHUB_OAUTH_ALLOW_HTTP"] = "true"
        self.assertFalse(auth.is_auth_enabled())

    def test_http_policy_cannot_be_changed_through_config_api(self):
        from src.core.config_manager import ConfigManager
        from src.core.config_registry import get_field_definition
        from src.services.system_config_service import SystemConfigService

        schema = get_field_definition("GITHUB_OAUTH_ALLOW_HTTP", "true")
        self.assertFalse(schema["is_editable"])
        service = SystemConfigService(manager=ConfigManager(env_path=self.env_path))
        result = service.validate([{"key": "GITHUB_OAUTH_ALLOW_HTTP", "value": "false"}])
        self.assertTrue(any(issue["key"] == "GITHUB_OAUTH_ALLOW_HTTP" and issue["code"] == "auth_server_managed"
                            for issue in result["issues"]))

    def test_callback_validation_stays_strict(self):
        config = auth.get_github_auth_config()
        for url in [
            "ftp://dsa.example.com" + auth.GITHUB_CALLBACK_PATH,
            "http://user:password@dsa.example.com" + auth.GITHUB_CALLBACK_PATH,
            "http://dsa.example.com:invalid" + auth.GITHUB_CALLBACK_PATH,
            "http://dsa.example.com" + auth.GITHUB_CALLBACK_PATH + "?next=/",
            "http://dsa.example.com" + auth.GITHUB_CALLBACK_PATH + "#fragment",
            "http://dsa.example.com/wrong-path",
        ]:
            with self.subTest(url=url):
                self.assertFalse(replace(config, callback_url=url).configured)
        self.assertFalse(replace(config, allowed_users=frozenset()).configured)
        self.assertFalse(replace(config, valid_allowlist=False).configured)

    def test_https_cookie_remains_secure(self):
        os.environ["GITHUB_OAUTH_CALLBACK_URL"] = "https://dsa.example.com" + auth.GITHUB_CALLBACK_PATH
        response = self.client.get("/api/v1/auth/github/login")
        self.assertIn("Secure", response.headers["set-cookie"])

    def test_http_login_keeps_pkce_state_allowlist_and_signed_session(self):
        response = self.client.get("/api/v1/auth/github/login?redirect=/")
        self.assertEqual(response.status_code, 303)
        cookie = response.headers["set-cookie"]
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=lax", cookie)
        self.assertNotIn("Secure", cookie)
        params = parse_qs(urlsplit(response.headers["location"]).query)
        self.assertEqual(params["code_challenge_method"], ["S256"])
        state = params["state"][0]
        challenge = params["code_challenge"][0]
        self.assertIsNone(auth.verify_oauth_state(self.client.cookies.get(auth.OAUTH_COOKIE_NAME), "wrong-state"))
        calls = []

        def provider(request):
            calls.append(request.url.path)
            if request.url.path == "/login/oauth/access_token":
                form = parse_qs(request.content.decode())
                actual = base64.urlsafe_b64encode(hashlib.sha256(form["code_verifier"][0].encode()).digest()).decode().rstrip("=")
                self.assertEqual(actual, challenge)
                return httpx.Response(200, json={"access_token": "test-token", "token_type": "bearer"})
            self.assertEqual(request.headers["Authorization"], "Bearer test-token")
            if request.url.path == "/user":
                return httpx.Response(200, json={
                    "id": 1, "login": "allowed-user", "name": "Allowed",
                    "avatar_url": "https://avatars.githubusercontent.com/u/1",
                })
            self.assertEqual(request.url.path, "/user/emails")
            return httpx.Response(200, json=[{"email": "user@example.com", "verified": True, "primary": True}])

        original_client = httpx.AsyncClient
        with patch.object(endpoint.httpx, "AsyncClient", side_effect=lambda **kwargs: original_client(
                transport=httpx.MockTransport(provider), **kwargs)):
            response = self.client.get("/api/v1/auth/github/callback", params={"state": state, "code": "test-code"})
        self.assertEqual(response.status_code, 303)
        self.assertEqual(response.headers["location"], "/")
        status = self.client.get("/api/v1/auth/status").json()
        self.assertTrue(status["loggedIn"])
        self.assertEqual(status["user"]["login"], "allowed-user")
        self.assertEqual(calls, ["/login/oauth/access_token", "/user", "/user/emails"])
        os.environ["GITHUB_OAUTH_ALLOW_HTTP"] = "false"
        self.assertFalse(self.client.get("/api/v1/auth/status").json()["loggedIn"])
        os.environ["GITHUB_OAUTH_ALLOW_HTTP"] = "true"
        os.environ["GITHUB_ALLOWED_USERS"] = "someone-else"
        self.assertFalse(self.client.get("/api/v1/auth/status").json()["loggedIn"])


if __name__ == "__main__":
    unittest.main()
