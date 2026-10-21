#!/usr/bin/env python3
"""Bundled TypeSafe transport. Credentials stay in the environment or Keychain."""
import getpass
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

ENDPOINT = "https://api.typesafe.ai/v1/systemone"
MAX_BYTES = 1024 * 1024


class ClientError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ClientError("TypeSafe redirect refused")


def credential():
    key = os.environ.get("TYPESAFE_API_KEY")
    if not key and sys.platform == "darwin":
        service = os.environ.get("JEV_TYPESAFE_KEYCHAIN_SERVICE", "jev-companion-typesafe")
        account = os.environ.get("JEV_TYPESAFE_KEYCHAIN_ACCOUNT", getpass.getuser())
        try:
            result = subprocess.run(
                ["/usr/bin/security", "find-generic-password", "-s", service, "-a", account, "-w"],
                capture_output=True, text=True, timeout=5, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            raise ClientError("No TypeSafe credential") from None
        if result.returncode == 0:
            key = result.stdout.strip()
    if not key or len(key) > 8192 or any(ord(c) < 33 or ord(c) > 126 for c in key):
        raise ClientError("No TypeSafe credential")
    return key


def evaluate(payload):
    if not isinstance(payload, dict):
        raise ClientError("Invalid TypeSafe request")
    body = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode("utf-8")
    if len(body) > MAX_BYTES:
        raise ClientError("TypeSafe request too large")
    req = urllib.request.Request(ENDPOINT, data=body, headers={
        "Authorization": "Bearer " + credential(), "Content-Type": "application/json",
        "Accept": "application/json", "User-Agent": "jev-companion/0.1.0",
    }, method="POST")
    try:
        # Standard TLS verification and configured OS/environment proxies apply.
        # The parent engine enforces a 60-second subprocess wall-clock limit.
        with urllib.request.build_opener(NoRedirect()).open(req, timeout=45) as response:
            raw = response.read(MAX_BYTES + 1)
    except urllib.error.HTTPError as exc:
        raise ClientError("TypeSafe HTTP %d" % exc.code) from None
    except (urllib.error.URLError, OSError):
        raise ClientError("TypeSafe request failed") from None
    if len(raw) > MAX_BYTES:
        raise ClientError("TypeSafe response too large")
    try:
        result = json.loads(raw)
    except (ValueError, UnicodeError):
        raise ClientError("Invalid TypeSafe response") from None
    if not isinstance(result, dict):
        raise ClientError("Invalid TypeSafe response")
    return result


def main():
    try:
        if sys.argv[1:] != ["evaluate", "-"]:
            raise ClientError("Usage: typesafe_client.py evaluate -")
        raw = sys.stdin.buffer.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            raise ClientError("TypeSafe request too large")
        result = evaluate(json.loads(raw))
        print(json.dumps(result, ensure_ascii=False, allow_nan=False))
        return 0
    except ClientError as exc:
        print(str(exc), file=sys.stderr)
    except Exception:
        # Provider bodies, chat text, request headers and credentials never enter errors.
        print("TypeSafe request failed", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
