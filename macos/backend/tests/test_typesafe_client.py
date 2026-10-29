"""Transport regressions use fixtures, never live credentials or API calls."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
import urllib.error
from unittest import mock

CLIENT = Path(__file__).resolve().parents[1] / "typesafe_client.py"
spec = importlib.util.spec_from_file_location("typesafe_client", CLIENT)
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)


class ClientTests(unittest.TestCase):
    @mock.patch.dict(os.environ, {"TYPESAFE_API_KEY": "test-fixture-key"}, clear=True)
    def test_environment_credential_precedes_keychain(self):
        with mock.patch.object(client.subprocess, "run") as process:
            self.assertEqual(client.credential(), "test-fixture-key")
            process.assert_not_called()

    @mock.patch.dict(os.environ, {}, clear=True)
    def test_missing_keychain_credential_is_sanitized(self):
        result = subprocess.CompletedProcess([], 1, "", "private diagnostic")
        with mock.patch.object(client.sys, "platform", "darwin"), mock.patch.object(client.subprocess, "run", return_value=result):
            with self.assertRaises(client.ClientError) as caught:
                client.credential()
        self.assertIn("No TypeSafe credential", str(caught.exception))
        self.assertIn("jev-companion-typesafe", str(caught.exception))
        self.assertNotIn("private diagnostic", str(caught.exception))

    @mock.patch.dict(os.environ, {"TYPESAFE_API_KEY": "   "}, clear=True)
    def test_empty_environment_credential_does_not_read_keychain(self):
        with mock.patch.object(client.sys, "platform", "darwin"), mock.patch.object(client.subprocess, "run") as process:
            with self.assertRaisesRegex(client.ClientError, "TYPESAFE_API_KEY is empty"):
                client.credential()
        process.assert_not_called()

    @mock.patch.dict(os.environ, {"TYPESAFE_API_KEY": "test-fixture-key\n"}, clear=True)
    def test_surrounding_whitespace_is_removed_before_use(self):
        with mock.patch.object(client.subprocess, "run") as process:
            self.assertEqual(client.credential(), "test-fixture-key")
        process.assert_not_called()

    @mock.patch.dict(os.environ, {}, clear=True)
    def test_non_darwin_missing_credential_does_not_touch_keychain(self):
        with mock.patch.object(client.sys, "platform", "linux"), mock.patch.object(client.subprocess, "run") as process:
            with self.assertRaisesRegex(client.ClientError, "does not read other tools"):
                client.credential()
        process.assert_not_called()

    def test_setup_report_never_returns_the_key(self):
        samples = {
            "env_unset": {},
            "env_empty": {"TYPESAFE_API_KEY": "  "},
            "env_invalid": {"TYPESAFE_API_KEY": "leak-this-key\nmore"},
            "env_present": {"TYPESAFE_API_KEY": "leak-this-key"},
        }
        for expected, values in samples.items():
            with self.subTest(expected=expected), mock.patch.dict(os.environ, values, clear=True):
                report = client.setup_report()
                blob = json.dumps(report, ensure_ascii=False)
                self.assertEqual(report["credential_setup"], expected)
                self.assertNotIn("leak-this-key", blob)
                self.assertNotIn("TYPESAFE_API_KEY=", blob)

    @mock.patch.dict(os.environ, {"JEV_TYPESAFE_KEYCHAIN_SERVICE": "test-service", "JEV_TYPESAFE_KEYCHAIN_ACCOUNT": "test-account"}, clear=True)
    def test_explicit_keychain_reference(self):
        result = subprocess.CompletedProcess([], 0, "test-fixture-key\n", "")
        with mock.patch.object(client.sys, "platform", "darwin"), mock.patch.object(client.subprocess, "run", return_value=result) as run:
            self.assertEqual(client.credential(), "test-fixture-key")
            self.assertEqual(run.call_args.args[0], ["/usr/bin/security", "find-generic-password", "-s", "test-service", "-a", "test-account", "-w"])

    def test_invalid_credential_cannot_inject_headers(self):
        for raw in ("bad\r\nX-Secret: value", '"test-fixture-key"', "bad key"):
            with self.subTest(raw=raw), mock.patch.dict(os.environ, {"TYPESAFE_API_KEY": raw}, clear=True):
                with mock.patch.object(client.subprocess, "run") as process:
                    with self.assertRaisesRegex(client.ClientError, "^TypeSafe credential format rejected$"):
                        client.credential()
                process.assert_not_called()

    def test_success_preserves_official_response(self):
        body = {"answers": {}, "usage": {"input_tokens": 8}, "model": "jev-fixture"}
        opener = mock.MagicMock()
        opener.open.return_value.__enter__.return_value.read.return_value = json.dumps(body).encode()
        with mock.patch.object(client, "credential", return_value="test-fixture-key"), mock.patch.object(client.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(client.evaluate({"state": "synthetic", "questions": {}}), body)
        req = opener.open.call_args.args[0]
        self.assertEqual(req.full_url, client.ENDPOINT)
        self.assertEqual(req.get_header("Authorization"), "Bearer test-fixture-key")
        self.assertEqual(json.loads(req.data)["state"], "synthetic")

    def test_redirects_refused_before_forwarding_credentials(self):
        with self.assertRaisesRegex(client.ClientError, "redirect refused"):
            client.NoRedirect().redirect_request(None, None, 307, "", {}, "https://example.invalid/")

    def test_http_error_does_not_echo_provider_body(self):
        opener = mock.MagicMock()
        opener.open.side_effect = urllib.error.HTTPError(client.ENDPOINT, 401, "private message", {}, io.BytesIO(b"private body"))
        with mock.patch.object(client, "credential", return_value="test-fixture-key"), mock.patch.object(client.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(client.ClientError, "^TypeSafe HTTP 401$"):
                client.evaluate({})

    def test_network_error_is_sanitized(self):
        opener = mock.MagicMock()
        opener.open.side_effect = urllib.error.URLError("private request and token")
        with mock.patch.object(client, "credential", return_value="test-fixture-key"), mock.patch.object(client.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(client.ClientError, "^TypeSafe request failed$"):
                client.evaluate({})

    def test_response_limit_and_json_validation(self):
        for raw, message in [(b"x" * (client.MAX_BYTES + 1), "too large"), (b"invalid-json", "Invalid"), (b"[]", "Invalid")]:
            with self.subTest(message=message):
                opener = mock.MagicMock()
                opener.open.return_value.__enter__.return_value.read.return_value = raw
                with mock.patch.object(client, "credential", return_value="test-fixture-key"), mock.patch.object(client.urllib.request, "build_opener", return_value=opener):
                    with self.assertRaisesRegex(client.ClientError, message):
                        client.evaluate({})

    def test_bad_cli_input_never_reads_credentials(self):
        result = subprocess.run([sys.executable, str(CLIENT), "evaluate", "-"], input="invalid-json", text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "TypeSafe request failed\n")


if __name__ == "__main__":
    unittest.main()
