#!/usr/bin/env python3
"""The one origin a Supabase project's clients talk to, over local services.

    supabase-gateway.py <port> <auth-port> <rest-port> <anon-key> <service-role-key>

A hosted project answers every client at `https://<ref>.supabase.co`: Kong
routes `/auth/v1/*` to Supabase Auth (GoTrue) and `/rest/v1/*` to the Data
API (PostgREST), and refuses any request whose `apikey` is not one of the
project's two keys. This does exactly that and nothing else, in front of the
real GoTrue and PostgREST binaries testing/lib/local-supabase.sh starts — so
supabase-js, in the built Worker, signs users up and reads the tables
through the same paths, headers and JWT roles it uses against a real
project, and row-level security is enforced by Postgres, not by a stand-in.
"""
import http.client
import http.server
import json
import sys

PORT, AUTH, REST = (int(x) for x in sys.argv[1:4])
KEYS = set(sys.argv[4:6])
ROUTES = {"/auth/v1": AUTH, "/rest/v1": REST}
HOP = {"connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade",
       "proxy-authorization", "proxy-authenticate", "host", "content-length"}


class Gateway(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # one line per request, to the e2e's log
        sys.stderr.write("gateway: " + (fmt % args) + "\n")

    def refuse(self, status, message):
        body = json.dumps({"message": message}).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def forward(self):
        prefix = next((p for p in ROUTES if self.path == p or self.path.startswith(p + "/") or self.path.startswith(p + "?")), None)
        if prefix is None:
            return self.refuse(404, f"no route for {self.path}")
        query = self.path.split("?", 1)[1] if "?" in self.path else ""
        apikey = self.headers.get("apikey") or dict(
            kv.split("=", 1) for kv in query.split("&") if "=" in kv).get("apikey")
        if apikey not in KEYS:
            return self.refuse(401, "Invalid API key")
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        conn = http.client.HTTPConnection("127.0.0.1", ROUTES[prefix], timeout=60)
        try:
            conn.request(self.command, self.path[len(prefix):] or "/", body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
        except OSError as e:
            return self.refuse(502, f"upstream {prefix} unreachable: {e}")
        finally:
            conn.close()
        self.send_response(resp.status, resp.reason)
        for k, v in resp.getheaders():
            if k.lower() not in HOP:
                self.send_header(k, v)
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = forward


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Gateway).serve_forever()
