#!/usr/bin/env python3
"""smtp-auth-probe.py — one SMTP session: connect, EHLO, AUTH, QUIT (ADR-0083).

preflight calls this to prove the SMTP relay of an environment is live and
accepts the keyring credential. Standard library only, so it runs on any
workstation and on a CI runner without an install step.

Usage: smtp-auth-probe.py HOST PORT USER
       The password arrives on stdin, never on argv.

TLS follows the relay: port 465 is implicit TLS, any other port upgrades with
STARTTLS when the relay advertises it. A relay that advertises no AUTH is a
miss.

The probe applies the rule of the daemon's client (Go net/smtp PlainAuth):
it sends no credential in clear text to a host other than localhost,
127.0.0.1 or ::1. A relay that offers no TLS to another host is a miss,
because the daemon could not send through it (hosted#126).

Exit codes: 0 EHLO and AUTH accepted, 1 the relay refused a step or did not
answer, 2 bad usage.
"""

import smtplib
import ssl
import sys

# The hosts to which Go net/smtp PlainAuth sends a credential without TLS.
CLEAR_TEXT_HOSTS = {"localhost", "127.0.0.1", "::1"}


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print("usage: smtp-auth-probe.py HOST PORT USER  (password on stdin)", file=sys.stderr)
        return 2
    host, port_text, user = argv[1], argv[2], argv[3]
    try:
        port = int(port_text)
    except ValueError:
        print(f"port {port_text!r} is not a number", file=sys.stderr)
        return 2
    password = sys.stdin.read().rstrip("\n")

    try:
        if port == 465:
            client = smtplib.SMTP_SSL(host, port, timeout=10, context=ssl.create_default_context())
        else:
            client = smtplib.SMTP(host, port, timeout=10)
    except OSError as exc:
        print(f"{host}:{port} did not accept a TCP connection: {exc}")
        return 1

    steps = []
    tls = port == 465
    try:
        code, _ = client.ehlo()
        if code != 250:
            print(f"{host}:{port} answered EHLO with {code}")
            return 1
        steps.append("EHLO ok")
        if port != 465 and client.has_extn("starttls"):
            client.starttls(context=ssl.create_default_context())
            client.ehlo()
            tls = True
            steps.append("STARTTLS ok")
        if not tls and host not in CLEAR_TEXT_HOSTS:
            print(f"{host}:{port} offers no TLS, and the daemon sends no credential in clear text to a host "
                  "other than localhost (Go net/smtp PlainAuth). The daemon cannot send through this relay")
            return 1
        if not client.has_extn("auth"):
            print(f"{host}:{port} advertises no AUTH after EHLO")
            return 1
        client.login(user, password)
        steps.append(f"AUTH ok as {user}")
        client.quit()
    except smtplib.SMTPAuthenticationError as exc:
        print(f"{host}:{port} refused AUTH for {user}: {exc.smtp_code} {exc.smtp_error!r}")
        return 1
    except (smtplib.SMTPException, OSError) as exc:
        print(f"{host}:{port} session failed after {', '.join(steps) or 'connect'}: {exc}")
        return 1

    print(f"{host}:{port} {', '.join(steps)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
