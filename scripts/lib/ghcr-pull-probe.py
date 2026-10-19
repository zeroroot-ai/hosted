#!/usr/bin/env python3
"""ghcr-pull-probe.py — does the GHCR pull token of the keyring work?

Check 11 of scripts/preflight.sh (hosted#601). Check 1 proves only that
GHCR_PULL_TOKEN is present and matches its fingerprint. On 2026-10-11 a
revoked token passed preflight, and the staging recreate and the drill then
stopped at the copy of the belief trainer image with a 403 from GHCR. The
cluster pulls the private first-party images with the same token, so a dead
token is also an ImagePullBackOff later. Preflight asks GHCR for a pull token
on one private first-party package and lists its tags with it, the way a
registry client does.

The token is read from the environment variable GHCR_PULL_TOKEN, never from
an argument, so it never shows in a process list.

Usage: GHCR_PULL_TOKEN=<token> ghcr-pull-probe.py
Exit:  0 the token reads the package; one line on stdout
       1 GHCR refused the token; the reason on stderr
       2 could not run; NOT a pass
"""

from __future__ import annotations

import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

REGISTRY = os.environ.get("GHCR_REGISTRY", "https://ghcr.io")
# billing is the private first-party package (ADR-0084): a token that can
# pull it can pull every first-party image.
PACKAGE = os.environ.get("GHCR_PROBE_PACKAGE", "zeroroot-ai/billing")


def main() -> int:
    token = os.environ.get("GHCR_PULL_TOKEN", "")
    if not token:
        sys.stderr.write("GHCR_PULL_TOKEN is not set\n")
        return 2
    query = urllib.parse.urlencode({"scope": "repository:%s:pull" % PACKAGE, "service": "ghcr.io"})
    req = urllib.request.Request(REGISTRY + "/token?" + query)
    req.add_header("Authorization", "Basic " + base64.b64encode(("x-access-token:" + token).encode()).decode())
    # Step 1: the token service. A revoked token gets a 403 here.
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            bearer = json.load(resp).get("token", "")
    except urllib.error.HTTPError as e:
        sys.stderr.write("GET /token for %s: HTTP %d\n" % (PACKAGE, e.code))
        return 1
    except (urllib.error.URLError, OSError, ValueError) as e:
        sys.stderr.write("could not reach %s: %s\n" % (REGISTRY, e))
        return 2
    if not bearer:
        sys.stderr.write("GET /token for %s: no token in the answer\n" % PACKAGE)
        return 1
    # Step 2: one read with the bearer token. A token service can issue a
    # token with an empty access list for a valid credential that has no read
    # on the package. Only a read proves the pull.
    req = urllib.request.Request(REGISTRY + "/v2/%s/tags/list?n=1" % PACKAGE)
    req.add_header("Authorization", "Bearer " + bearer)
    try:
        with urllib.request.urlopen(req, timeout=15):
            pass
    except urllib.error.HTTPError as e:
        sys.stderr.write("GET /v2/%s/tags/list: HTTP %d\n" % (PACKAGE, e.code))
        return 1
    except (urllib.error.URLError, OSError) as e:
        sys.stderr.write("could not reach %s: %s\n" % (REGISTRY, e))
        return 2
    sys.stdout.write("GHCR grants the keyring token pull on %s, and it lists the tags\n" % PACKAGE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
