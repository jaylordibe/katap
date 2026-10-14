"""A stub HTTP server for lib/smoke-check.sh: the first path segment picks the answer.

    python3 tests/stub_server.py <port>
"""
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

READY = b'{"success":true,"message":"ok","status":"ready"}'


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, code, body=b'', headers=None):
        self.send_response(code)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass  # the client gave up first, which is what the timeout cases test

    def do_GET(self):
        scenario = self.path.strip('/').split('/')[0]
        if scenario == 'ready':
            self.answer(200, READY)
        elif scenario == 'plain':
            self.answer(200, b'<html>ok</html>')
        elif scenario == 'not-ready':
            self.answer(200, b'{"success":true,"status":"starting"}')
        elif scenario == 'unavailable':
            self.answer(503, b'{"status":"unavailable"}')
        elif scenario == 'redirect':
            self.answer(302, headers={'Location': '/ready'})
        elif scenario == 'not-found':
            self.answer(404)
        elif scenario == 'unauthorized':
            self.answer(401)
        elif scenario == 'slow':
            time.sleep(3)
            self.answer(200, READY)
        else:
            self.answer(500)


HTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
