#!/usr/bin/env python3
"""Local stand-in for the Messages API streaming endpoint, for testing the Swift
transport without an API key or network.

    python3 scripts/mock-anthropic.py [--port 8765] [--first-token-delay 0.4] [--token-delay 0.03]

Behaviour by request content:
- question contains "Rust"     -> answers "Not in your notes."
- question contains "refuse"   -> mid-stream refusal (stop_reason "refusal")
- question contains "overload" -> mid-stream error event (overloaded_error)
- header x-api-key == "bad"    -> HTTP 401 with an authentication_error body
- otherwise a canned bulleted answer, streamed word by word.
The first request per model reports a cache write; later ones a cache read.
"""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ARGS = None
SEEN_MODELS = set()


def sse(handler, event_type, payload):
    handler.wfile.write(f"event: {event_type}\ndata: {json.dumps(payload)}\n\n".encode())
    handler.wfile.flush()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        if self.headers.get("x-api-key") == "bad":
            data = json.dumps({"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}).encode()
            self.send_response(401)
            self.send_header("content-type", "application/json")
            self.send_header("request-id", "req_mock_401")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        model = body.get("model", "claude-sonnet-5-5")
        question = body["messages"][-1]["content"][0]["text"].rsplit("Question:", 1)[-1]
        first = model not in SEEN_MODELS
        SEEN_MODELS.add(model)

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()

        time.sleep(ARGS.first_token_delay / 2)
        sse(self, "message_start", {"type": "message_start", "message": {
            "id": "msg_mock", "type": "message", "role": "assistant", "model": model, "content": [],
            "usage": {"input_tokens": 410, "output_tokens": 1,
                      "cache_creation_input_tokens": 950 if first else 0,
                      "cache_read_input_tokens": 0 if first else 950}}})
        sse(self, "ping", {"type": "ping"})
        sse(self, "content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
        time.sleep(ARGS.first_token_delay / 2)

        if "Rust" in question:
            words = ["Not", " in", " your", " notes.\nClosest:", " [1]", " lists", " the", " official", " SDK", " languages."]
        else:
            words = ["- **Five", " minutes", " by", " default**,", " refreshed", " on", " every", " read", " [2]\n",
                     "- One-hour", " TTL", " costs", " 2x", " to", " write", " [2]"]

        for i, word in enumerate(words):
            sse(self, "content_block_delta", {"type": "content_block_delta", "index": 0,
                                              "delta": {"type": "text_delta", "text": word}})
            if i == 3 and "overload" in question:
                sse(self, "error", {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}})
                return
            if i == 3 and "refuse" in question:
                sse(self, "content_block_stop", {"type": "content_block_stop", "index": 0})
                sse(self, "message_delta", {"type": "message_delta", "delta": {
                    "stop_reason": "refusal", "stop_details": {"type": "refusal", "category": "general_harms"}},
                    "usage": {"output_tokens": 4}})
                sse(self, "message_stop", {"type": "message_stop"})
                return
            time.sleep(ARGS.token_delay)

        sse(self, "content_block_stop", {"type": "content_block_stop", "index": 0})
        sse(self, "message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                                    "usage": {"output_tokens": len(words) * 2}})
        sse(self, "message_stop", {"type": "message_stop"})


def main():
    global ARGS
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--first-token-delay", type=float, default=0.4)
    parser.add_argument("--token-delay", type=float, default=0.03)
    ARGS = parser.parse_args()
    ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
