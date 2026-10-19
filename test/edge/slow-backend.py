import http.server, socketserver, sys, time
HOLD = int(sys.argv[1]) if len(sys.argv) > 1 else 90
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_POST(self):
        # Headers immediately, then silence, then a byte. That is the shape of a
        # mission that starts, thinks for a long time, then emits an event.
        self.send_response(200)
        self.send_header("Content-Type", "application/grpc")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        time.sleep(HOLD)
        self.wfile.write(b"1\r\nx\r\n0\r\n\r\n")
        self.wfile.flush()
    do_GET = do_POST
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.ThreadingTCPServer(("0.0.0.0", 9999), H) as s:
    s.serve_forever()
