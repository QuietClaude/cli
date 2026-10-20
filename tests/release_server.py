import http.server
import socketserver
import sys

ROOT = sys.argv[1]


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - - %s\n" % (self.address_string(), fmt % args))
        sys.stderr.flush()


def main() -> int:
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
        sys.stdout.write("%d\n" % httpd.server_address[1])
        sys.stdout.flush()
        httpd.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
