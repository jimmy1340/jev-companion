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


def normalize_secret(raw):
    """Return a header-safe secret, or None when the value is absent.

    Present but unsafe values raise ClientError. The message never includes the
    secret. Surrounding whitespace is removed; a matching pair of quotes is
    rejected so a shell paste is not sent on the user's behalf.
    """
    if raw is None:
        return None
    if not isinstance(raw, str):
        raise ClientError("TypeSafe credential format rejected")
    key = raw.strip()
    if len(key) >= 2 and key[0] == key[-1] and key[0] in ("'", '"'):
        raise ClientError("TypeSafe credential format rejected")
    if not key:
        return None
    if len(key) > 8192 or any(ord(char) < 33 or ord(char) > 126 for char in key):
        raise ClientError("TypeSafe credential format rejected")
    return key


def setup_report():
    """Describe TYPESAFE_API_KEY locally. Never reads Keychain, the network, or the key."""
    if "TYPESAFE_API_KEY" not in os.environ:
        return {
            "credential_setup": "env_unset",
            "credential_hint": (
                "TYPESAFE_API_KEY 未设置。从 Finder 启动时请在钥匙串新建通用密码："
                "服务名 jev-companion-typesafe，账号为 id -un 的短用户名。"
                "此检查不会打开钥匙串，也不会访问 TypeSafe 或其他工具的账号。"
            ),
        }
    try:
        key = normalize_secret(os.environ.get("TYPESAFE_API_KEY"))
    except ClientError:
        key = False
    if key is None:
        return {
            "credential_setup": "env_empty",
            "credential_hint": (
                "TYPESAFE_API_KEY 已设置但为空，因此不会改去读钥匙串。"
                "请填入这台电脑自己的密钥，或取消该环境变量后再使用 jev-companion-typesafe。"
            ),
        }
    if key is False:
        return {
            "credential_setup": "env_invalid",
            "credential_hint": (
                "TYPESAFE_API_KEY 格式不正确。请使用一行可打印字符，去掉空格、换行和两侧引号。"
                "状态结果不会包含密钥本身。"
            ),
        }
    return {
        "credential_setup": "env_present",
        "credential_hint": (
            "TYPESAFE_API_KEY 已设置且格式可接受。是否有效要等一次真实分析；"
            "此检查没有调用 TypeSafe，也没有输出密钥。"
        ),
    }


def credential():
    # A set variable wins, even when blank, so an empty shell value cannot
    # silently fall through to some other Keychain item.
    if "TYPESAFE_API_KEY" in os.environ:
        key = normalize_secret(os.environ.get("TYPESAFE_API_KEY"))
        if not key:
            raise ClientError("No TypeSafe credential: TYPESAFE_API_KEY is empty")
        return key
    if sys.platform == "darwin":
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
            key = normalize_secret(result.stdout)
            if key:
                return key
    raise ClientError(
        "No TypeSafe credential. Set TYPESAFE_API_KEY or add Keychain item "
        "jev-companion-typesafe for the current user. This client does not read other tools' accounts."
    )


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
