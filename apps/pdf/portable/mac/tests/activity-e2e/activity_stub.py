#!/usr/bin/env python3
"""A stand-in for the assistant's model, for the last-opened/last-viewed end-to-end test (run_activity_e2e.py).

It answers OpenRouter's chat completions API on 127.0.0.1 only, the way a model that follows the system prompt would
with the owner's request "close any document I have not viewed since a week": it reads list_workspace for the current
time, asks it again for the documents not viewed since a week before, closes them in one close_document call, and says
which ones no record tells about. Everything that happens to the tabs comes from the app's real tools.

Usage: activity_stub.py <port file> <log file>
"""
import datetime
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def call(name, arguments, number):
    return {"role": "assistant", "content": "", "tool_calls": [
        {"id": f"stub-{number}", "type": "function", "function": {"name": name, "arguments": json.dumps(arguments)}}]}


def text(content):
    return {"role": "assistant", "content": content}


def answer(messages, tools, number):
    if not tools:
        return text("Document dates")  # the chat's title
    users = [i for i, m in enumerate(messages) if m["role"] == "user"]
    question = messages[users[-1]]["content"].lower() if users else ""
    results = [json.loads(m["content"]) for m in messages[users[-1] + 1:] if m["role"] == "tool"] if users else []
    if "undo" in question:
        return call("undo_action", {}, number) if not results else text(
            "Reopened them." if results[-1].get("undone") else "Undo failed: " + results[-1].get("error", ""))
    if "when did i last view" in question:
        if not results:
            return call("list_workspace", {"count": 100}, number)
        rows = "\n".join(f"| {t['title']} | {t.get('last_viewed') or 'not viewed'} | {t.get('last_opened')} |"
                         for t in results[-1]["tabs"])
        return text("| Document | Last viewed | Last opened |\n|---|---|---|\n" + rows)
    if "viewed since a week" in question:
        if not results:
            return call("list_workspace", {"count": 100}, number)
        if len(results) == 1:
            now = datetime.datetime.fromisoformat(results[0]["now"])
            since = (now - datetime.timedelta(days=7)).isoformat(timespec="seconds")
            return call("list_workspace", {"notViewedSince": since, "count": 100}, number)
        listed = results[1]
        if len(results) == 2:
            ids = [t["path"] for t in listed["tabs"]]
            return call("close_document", {"paths": ids}, number) if ids else text("Every document was viewed this week.")
        closed = results[2]
        if "error" in closed:
            return text("Closing failed: " + closed["error"])
        unknown = listed["notViewedSince"]["noViewRecord"]["count"]
        return text(f"Closed {closed['closed']} documents not viewed since {listed['notViewedSince']['since'][:10]} "
                    f"(dates before this week are partly estimated). {unknown} documents have no view record, so I left "
                    "them open. Undo reopens the closed ones.")
    return text("I have nothing to do for that.")


class Handler(BaseHTTPRequestHandler):
    counter = 0

    def log_message(self, *args):
        pass

    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply({"data": [{"id": "e2e/stub-model", "name": "Stub", "context_length": 200000,
                              "architecture": {"input_modalities": ["text", "image"]}}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        Handler.counter += 1
        tools = [t["function"]["name"] for t in request.get("tools", [])]
        try:
            message = answer(request["messages"], tools, Handler.counter)
        except Exception as error:  # the test reads this as the answer and fails on it
            message = text(f"stub error: {error!r}")
        with open(sys.argv[2], "a") as log:
            log.write(json.dumps({"tools": tools, "system": request["messages"][0]["content"],
                                  "last": request["messages"][-1], "reply": message}) + "\n")
        self.reply({"id": f"stub-{Handler.counter}", "object": "chat.completion", "model": "e2e/stub-model",
                    "choices": [{"index": 0, "message": message,
                                 "finish_reason": "tool_calls" if "tool_calls" in message else "stop"}],
                    "usage": {"prompt_tokens": 1000, "completion_tokens": 100, "total_tokens": 1100}})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()
