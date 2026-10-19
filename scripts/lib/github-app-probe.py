#!/usr/bin/env python3
"""github-app-probe.py — can the Argo CD GitHub App read the gitops repo?

Check 9 of scripts/preflight.sh (ADR-0083). Argo CD's app-of-apps clones the
gitops repo, which is private. Without a working credential the clone fails
with "failed to list refs: authentication required: Repository not found",
and the failure surfaces as stage 2 stalling to its cap with ONE Application
and an error nobody is reading. Measured on the 2026-09-14 staging bringup:
forty minutes spent, nothing converged, and the cause was three environment
variables that nothing named.

So this proves the credential live, before the bringup starts, exactly as
check 8 proves the DNS credential: mint an installation token from the App's
key, then read the repository with it.

Usage: github-app-probe.py <app-id> <installation-id> <pem-file> <owner/repo>
Exit:  0 the App's installation can read the repository; one line on stdout
       1 it cannot; the reason on stderr
       2 could not run (a missing tool or an unreadable key); NOT a pass

Tools: openssl for the RS256 signature. The rest is the standard library, so
this runs the same on a workstation and on an ubuntu runner.
"""

from __future__ import annotations

import base64
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"


def die(msg: str, code: int = 1) -> None:
    sys.stderr.write(msg.rstrip("\n") + "\n")
    raise SystemExit(code)


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def app_jwt(app_id: str, pem_file: str) -> str:
    """A short-lived RS256 JWT signed with the App's private key.

    iat is backdated by a minute: GitHub rejects a token whose iat is in the
    future, and a workstation clock that runs fast is not a credential fault.
    """
    now = int(time.time())
    header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    payload = b64url(
        json.dumps({"iat": now - 60, "exp": now + 540, "iss": app_id}).encode()
    )
    signing_input = f"{header}.{payload}".encode()
    try:
        proc = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", pem_file],
            input=signing_input,
            capture_output=True,
        )
    except FileNotFoundError:
        die("openssl is not on PATH, so the App JWT cannot be signed", 2)
    if proc.returncode != 0:
        die(
            "openssl could not sign with %s: %s"
            % (pem_file, proc.stderr.decode(errors="replace").strip()),
            2,
        )
    return f"{header}.{payload}.{b64url(proc.stdout)}"


def api(path: str, token: str, scheme: str, method: str = "GET") -> dict:
    req = urllib.request.Request(
        API + path,
        method=method,
        headers={
            "Authorization": f"{scheme} {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "zeroroot-preflight",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        try:
            detail = json.loads(body).get("message", body)
        except Exception:
            detail = body
        die("%s %s: HTTP %s %s" % (method, path, exc.code, detail.strip()))
    except urllib.error.URLError as exc:
        die("%s %s: %s" % (method, path, exc.reason), 2)
    raise AssertionError("unreachable")


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        die(
            "usage: github-app-probe.py <app-id> <installation-id> <pem-file> <owner/repo>",
            2,
        )
    app_id, installation_id, pem_file, repo = argv[0], argv[1], argv[2], argv[3]
    if "/" not in repo:
        die("'%s' is not an owner/repo" % repo, 2)

    jwt = app_jwt(app_id, pem_file)
    # The App itself, so a wrong app id is named as such rather than as a
    # failure to read the repository.
    app = api("/app", jwt, "Bearer")
    token = api(
        "/app/installations/%s/access_tokens" % installation_id, jwt, "Bearer", "POST"
    ).get("token", "")
    if not token:
        die("installation %s returned no access token" % installation_id)

    # The repository Argo clones, read with the INSTALLATION token. A token
    # that mints but cannot read this repo is the failure that matters: the
    # installation exists and the repository is not in its selection.
    info = api("/repos/%s" % repo, token, "token")
    sys.stdout.write(
        "app %s (%s) installation %s reads %s (private=%s)\n"
        % (
            app_id,
            app.get("slug", "?"),
            installation_id,
            info.get("full_name", repo),
            str(info.get("private", "?")).lower(),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
