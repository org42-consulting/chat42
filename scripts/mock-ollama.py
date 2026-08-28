#!/usr/bin/env python3
"""Records what Chat42 actually sends to Ollama.

Speaks just enough of the Ollama API to stand in for it: /api/tags so the app
finds a model, and /api/chat streaming NDJSON so a turn completes. Every chat
request body is appended to a JSONL file.

The point is to check the *payload*, not a model's recall. Asking a small model
"what was the budget?" and trusting its answer conflates two things: whether the
document reached the request, and whether the model was clever enough to use it.
Only the first is Chat42's job, and this asserts it directly.

    ./scripts/mock-ollama.py --port 11500 --record /tmp/ollama-requests.jsonl
"""

import argparse
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

RECORD_PATH = None
REPLY = "Recorded."


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # keep stdout clean; the recording file is the output

    def do_GET(self):
        if self.path.startswith("/api/tags"):
            body = json.dumps(
                {"models": [{"name": "mock:latest", "size": 1, "digest": "mock"}]}
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if not self.path.startswith("/api/chat"):
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw)
        except Exception:
            payload = {"unparsed": raw.decode("utf-8", "replace")}

        with open(RECORD_PATH, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload) + "\n")

        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.end_headers()
        # Ollama streams one JSON object per line, terminated by done: true.
        for chunk in REPLY.split(" "):
            line = json.dumps(
                {
                    "model": payload.get("model", "mock"),
                    "message": {"role": "assistant", "content": chunk + " "},
                    "done": False,
                }
            )
            self.wfile.write((line + "\n").encode())
            self.wfile.flush()
        tail = json.dumps(
            {"model": payload.get("model", "mock"), "message": None, "done": True}
        )
        self.wfile.write((tail + "\n").encode())
        self.wfile.flush()


def main():
    global RECORD_PATH
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=11500)
    parser.add_argument("--record", default="/tmp/ollama-requests.jsonl")
    args = parser.parse_args()

    RECORD_PATH = args.record
    open(RECORD_PATH, "w").close()

    server = HTTPServer(("127.0.0.1", args.port), Handler)
    print(f"mock ollama on http://127.0.0.1:{args.port}, recording to {RECORD_PATH}")
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
