#!/usr/bin/env python3
"""stripe-key-probe.py — does the Stripe secret key of the keyring work?

Check 10 of scripts/preflight.sh (hosted#450). A placeholder or a revoked key
lets the bringup finish, and each paid signup then stops at the card step:
"Invalid API Key provided: sk_test_*******lder". Measured on staging on
2026-10-05. So preflight proves the key live before the bringup starts: it
lists one price of the account, which the dashboard also reads.

The key is read from the environment variable STRIPE_SECRET_KEY, never from
an argument, so it never shows in a process list.

Usage: STRIPE_SECRET_KEY=<key> stripe-key-probe.py
Exit:  0 the key reads the account; one line on stdout
       1 Stripe refused it; the reason on stderr
       2 could not run; NOT a pass
"""

from __future__ import annotations

import base64
import json
import os
import sys
import urllib.error
import urllib.request

API = os.environ.get("STRIPE_API", "https://api.stripe.com")


def main() -> int:
    key = os.environ.get("STRIPE_SECRET_KEY", "")
    if not key:
        sys.stderr.write("STRIPE_SECRET_KEY is not set\n")
        return 2
    req = urllib.request.Request(API + "/v1/prices?limit=1")
    req.add_header("Authorization", "Basic " + base64.b64encode((key + ":").encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = json.load(resp)
    except urllib.error.HTTPError as e:
        try:
            msg = json.load(e).get("error", {}).get("message", "")
        except (ValueError, AttributeError):
            msg = ""
        sys.stderr.write("GET /v1/prices: HTTP %d %s\n" % (e.code, msg.replace(key, "<key>")))
        return 1
    except (urllib.error.URLError, OSError) as e:
        sys.stderr.write("could not reach %s: %s\n" % (API, e))
        return 2
    mode = "live" if key.startswith(("sk_live_", "rk_live_")) else "test"
    sys.stdout.write("the Stripe secret key reads the account (%s mode, %d price(s) listed)\n"
                     % (mode, len(body.get("data", []))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
