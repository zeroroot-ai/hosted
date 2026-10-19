#!/usr/bin/env python3
"""console-proxy.py: the private path of the Platform owner to the Zitadel
console (ADR-0093, hosted#437).

The public edge has no route for the Zitadel admin surface: /ui/console,
/admin/v1/, /management/v1/ and /zitadel. (charts#398). The console still has
to load at its own origin, https://<app host>, because Zitadel builds every
redirect and every API address of the console from the instance host
(ADR-0092). So a browser on the workstation maps the app host to this proxy,
and this proxy does on 127.0.0.1 what the edge does on the internet, for the
Zitadel paths only:

  /ui/console...  -> Zitadel core (the console)
  /ui/...         -> the Zitadel login (Login V2)
  everything else -> Zitadel core

Each request keeps its Host, and the proxy claims the instance host in
x-zitadel-instance-host and x-zitadel-public-host, the two headers that the
edge owns on the public path (charts#161). The two upstreams are kubectl
port-forwards on 127.0.0.1, so nothing here is reachable from another host.

TLS: a certificate that the caller made for this one run. The browser is told
to trust exactly that key (--ignore-certificate-errors-spki-list), so no CA
is installed anywhere.

Usage: console-proxy.py --listen PORT --host APP_HOST --zitadel PORT
                        --login PORT --cert FILE --key FILE
"""
from __future__ import annotations

import argparse
import re
import http.client
import http.server
import socketserver
import ssl
import sys

CLAIMED = {"x-zitadel-instance-host", "x-zitadel-public-host", "x-forwarded-host", "forwarded"}
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade",
}


def upstream_for(path: str) -> str:
    """Return "zitadel" or "login" for a request path, the way the edge routes it."""
    if path.startswith("/ui/console"):
        return "zitadel"
    if path.startswith("/ui/"):
        return "login"
    return "zitadel"


# A request path that the proxy forwards: origin-form, printable ASCII, no
# space and no line break. An absolute URL or a line break is refused, so the
# request line to the upstream always names 127.0.0.1 and one path.
PATH_OK = re.compile(r"^/[!-~]*$")


def safe_header(value: str) -> bool:
    """A header value with no line break, so it cannot start a second header."""
    return "\r" not in value and "\n" not in value


def make_handler(app_host: str, ports: dict[str, int]):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt: str, *args: object) -> None:
            sys.stderr.write("console-proxy: " + (fmt % args) + "\n")

        def _forward(self) -> None:
            if not PATH_OK.match(self.path):
                self.send_error(400, "the path must be an origin-form path")
                return
            path = self.path
            target = upstream_for(path)
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else None
            # The client may not claim an instance: drop each claim header in
            # any letter case, and the Host, then set them here.
            headers = {k: v for k, v in self.headers.items()
                       if k.lower() not in HOP_BY_HOP | CLAIMED | {"host"}}
            headers["Host"] = app_host
            headers["x-zitadel-instance-host"] = app_host
            headers["x-zitadel-public-host"] = app_host
            headers["X-Forwarded-Proto"] = "https"
            conn = http.client.HTTPConnection("127.0.0.1", ports[target], timeout=60)
            try:
                conn.request(self.command, path, body=body, headers=headers)
                resp = conn.getresponse()
                data = resp.read()
            except OSError as exc:
                self.send_error(502, f"{target} upstream: {exc}")
                return
            finally:
                conn.close()
            self.send_response(resp.status, resp.reason)
            for key, value in resp.getheaders():
                if key.lower() in HOP_BY_HOP or key.lower() == "content-length":
                    continue
                if not (safe_header(key) and safe_header(value)):
                    continue
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)

        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = _forward

    return Handler


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--listen", type=int, required=True)
    p.add_argument("--host", required=True, help="the app host, the Zitadel instance host")
    p.add_argument("--zitadel", type=int, required=True, help="local port of the Zitadel core forward")
    p.add_argument("--login", type=int, required=True, help="local port of the Zitadel login forward")
    p.add_argument("--cert", required=True)
    p.add_argument("--key", required=True)
    args = p.parse_args(argv[1:])
    server = Server(("127.0.0.1", args.listen),
                    make_handler(args.host, {"zitadel": args.zitadel, "login": args.login}))
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(args.cert, args.key)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    sys.stderr.write(f"console-proxy: https://{args.host} on 127.0.0.1:{args.listen}\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
