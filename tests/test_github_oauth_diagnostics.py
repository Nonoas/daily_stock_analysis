"""OAuth failure diagnostics must identify HTTP failures without exposing secrets."""

import unittest

import httpx

from api.v1.endpoints.auth import _log_github_lookup_failure


class GitHubOAuthDiagnosticsTests(unittest.TestCase):
    def capture(self, error):
        with self.assertLogs("api.v1.endpoints.auth", level="WARNING") as captured:
            _log_github_lookup_failure(error)
        output = "\n".join(captured.output)
        self.assertNotIn("private-secret", output)
        return output

    def test_profile_rate_limit_does_not_log_credentials_or_response_body(self):
        request = httpx.Request(
            "GET", "https://api.github.com/user?access_token=private-secret",
            headers={"Authorization": "Bearer private-secret"},
        )
        response = httpx.Response(
            403, request=request, headers={"x-ratelimit-remaining": "0"},
            json={"message": "private-secret"},
        )
        try:
            response.raise_for_status()
        except httpx.HTTPStatusError as error:
            output = self.capture(error)
        self.assertIn("stage=profile", output)
        self.assertIn("error=HTTPStatusError status=403 rate_limited=True", output)

    def test_exchange_timeout_does_not_log_request_body_or_exception_message(self):
        request = httpx.Request(
            "POST", "https://github.com/login/oauth/access_token",
            data={"code": "private-secret", "client_secret": "private-secret"},
        )
        output = self.capture(httpx.ConnectTimeout("private-secret", request=request))
        self.assertIn("stage=token_exchange error=ConnectTimeout status=None", output)

    def test_email_permissions_failure_is_not_reported_as_rate_limit(self):
        request = httpx.Request("GET", "https://api.github.com/user/emails")
        response = httpx.Response(401, request=request)
        output = self.capture(httpx.HTTPStatusError("private-secret", request=request, response=response))
        self.assertIn("stage=emails error=HTTPStatusError status=401 rate_limited=False", output)

    def test_json_error_and_http_error_without_request_are_safe(self):
        for error in (ValueError("private-secret"), httpx.ConnectError("private-secret")):
            with self.subTest(error=type(error).__name__):
                self.assertIn("stage=unknown", self.capture(error))


if __name__ == "__main__":
    unittest.main()
