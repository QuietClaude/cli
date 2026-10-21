"""A stand-in for dl.quietclaude.com. Serves /pro/download/<asset> from a folder, gated by the key.

Keys by prefix: VALID- serves the file, BAD- gets 403, LIMIT- gets 429 for the program (the checksum
files stay free, like the real server), DOWN- gets 503, NOREL- gets 404. A missing key is 403.
Prints its port, and writes one line per request to the log: the path and whether a key was sent.
"""
import http.server
import socketserver
import sys

ROOT = sys.argv[1]
LOG = sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def reply(self, code, body=b""):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        key = auth[7:] if auth.startswith("Bearer ") else ""
        with open(LOG, "a") as fh:
            fh.write("%s key=%s\n" % (self.path, "yes" if key else "no"))
        name = self.path.rsplit("/", 1)[-1]
        if not self.path.startswith("/pro/download/") or not key:
            return self.reply(403, b"a licence key is required\n")
        if key.startswith("BAD-"):
            return self.reply(403, b"this licence key is not valid\n")
        if key.startswith("DOWN-"):
            return self.reply(503, b"licence service unavailable\n")
        if key.startswith("NOREL-"):
            return self.reply(404, b"no release yet\n")
        if key.startswith("LIMIT-") and name.startswith("quietclaude-pro-"):
            return self.reply(429, b"too many downloads today for this key\n")
        if not key.startswith(("VALID-", "LIMIT-")):
            return self.reply(403, b"this licence key is not valid\n")
        try:
            with open("%s/%s" % (ROOT, name), "rb") as fh:
                return self.reply(200, fh.read())
        except OSError:
            return self.reply(404, b"file not found\n")


socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
    sys.stdout.write("%d\n" % httpd.server_address[1])
    sys.stdout.flush()
    httpd.serve_forever()
