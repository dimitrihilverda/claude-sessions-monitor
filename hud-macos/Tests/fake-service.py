#!/usr/bin/env python3
"""A stand-in for session-api.ps1, serving one session in each state.

The window has three states you cannot sit and wait for on demand: a session
that needs you, and a service that stops answering. Point the HUD at this with
CLAUDEDECK_PORT=8799 and you can look at all of them in a few seconds.
"""
import json, http.server, socketserver

PORT = 8799

PAYLOAD = {
    "generated": "2026-09-02T10:00:00+02:00",
    "attention": 1, "active": 1, "done": 1, "known": 3,
    "sessions": [
        {"session_id": "a1", "snoozed": False, "event": "Notification",
         "state": "attention", "cwd": "/Users/you/Code/shop-api",
         "name": "Checkout flow", "folder": "shop-api", "label": "Needs you",
         "why": "may I edit src/payments/webhook.ts?", "since": "09:58",
         "visible": True},
        {"session_id": "b2", "snoozed": False, "event": "PostToolUse",
         "state": "active", "cwd": "/Users/you/Code/docs",
         "name": "Getting started page", "folder": "docs", "label": "Working",
         "why": "rewrite the install section", "since": "09:51",
         "visible": True},
        {"session_id": "c3", "snoozed": False, "event": "Stop",
         "state": "done", "cwd": "/Users/you/Code/etl",
         "name": "Nightly import", "folder": "etl", "label": "Done",
         "why": "add a retry around the upload", "since": "09:30",
         "visible": True},
    ],
}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = (json.dumps(PAYLOAD).encode()
                if self.path.startswith("/sessions.json") else b"ok")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


socketserver.TCPServer.allow_reuse_address = True
print(f"stand-in service on http://127.0.0.1:{PORT}/  (ctrl-c to stop)")
with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as s:
    s.serve_forever()
