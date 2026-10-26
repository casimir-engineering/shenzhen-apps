#!/usr/bin/env python3
"""A stand-in for the assistant's model, for the document names end-to-end test (run_titles_e2e.py).

It answers OpenRouter's chat completions API on 127.0.0.1 only, the way a model that follows the system prompt and
the tool descriptions would with the owner's requests:

  sort  "Rename the docs whose names are UUIDs, with the type of document in the name, and sort General into groups
        that make sense. General must be empty in the end."  It lists the workspace, reads page 1 of every General
        document whose title is a UUID (in one reply), names each from what the page says (in one reply), lists the
        workspace again, creates one group per subject with all its documents (in one reply), checks General and
        says what it did, in the words the tools gave for files that kept their names.
  save  "Save the read-only ones as PDFs in Downloads."  It lists the workspace, reads page 1 of each read-only
        document for its revision, and starts one export-pdf document_job for each, without showing them.

Everything that happens to the documents comes from the app's real tools.

Usage: titles_stub.py <port file> <log file>
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UUID = re.compile(r"^[0-9a-f]{32}$|^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)

# What the first page says -> the name a model gives the document and the group it puts it in.
SUBJECTS = [
    ("MSK12C02", "MSK12C02 - toggle switch - datasheet", "Switches and Sensors"),
    ("LTE-C9901", "LTE-C9901 - IR emitter and detector - datasheet", "Switches and Sensors"),
    ("GDL6150", "GDL6150 - fingerprint sensor - datasheet", "Switches and Sensors"),
    ("Mothership", "Mothership - architecture block diagram", "Mothership"),
    ("USB PCB", "USB PCB 3744028 - final inspection report", "Mothership"),
    ("OV50X", "OV50X50 - camera module - datasheet", "Camera Module"),
    ("Camera bring-up", None, "Camera Module"),
]
COLORS = {"Switches and Sensors": "Slate", "Mothership": "Rose", "Camera Module": "Plum"}


def subject(text):
    for key, name, group in SUBJECTS:
        if key.lower() in text.lower():
            return name, group
    return None, None


def calls(pairs, number):
    return {"role": "assistant", "content": "", "tool_calls": [
        {"id": f"stub-{number}-{i}", "type": "function", "function": {"name": name, "arguments": json.dumps(arguments)}}
        for i, (name, arguments) in enumerate(pairs)]}


def text(content):
    return {"role": "assistant", "content": content}


def steps(messages):
    """The assistant turns since the person's last message, each with its calls and their results, in order."""
    last = max(i for i, m in enumerate(messages) if m["role"] == "user")
    turns, results = [], {}
    for m in messages[last + 1:]:
        if m["role"] == "tool":
            results[m.get("tool_call_id")] = json.loads(m["content"])
    for m in messages[last + 1:]:
        if m["role"] == "assistant" and m.get("tool_calls"):
            turns.append([(c["function"]["name"], json.loads(c["function"]["arguments"] or "{}"), results.get(c["id"], {}))
                          for c in m["tool_calls"]])
    return messages[last]["content"].lower(), turns


def general(listing):
    return [t for t in listing.get("tabs", []) if t.get("groupID") == "general"]


def sort(turns, number):
    if not turns:
        return calls([("list_workspace", {"count": 100})], number)
    if len(turns) == 1:
        named = [t for t in general(turns[0][0][2]) if UUID.match(t["title"])]
        if not named:
            return text("No document in General has a UUID for a name.")
        return calls([("read_pages", {"path": t["path"], "page": 1, "count": 1}) for t in named], number)
    if len(turns) == 2:
        renames = []
        for name, arguments, result in turns[1]:
            page = (result.get("pages") or [{}])[0].get("text", "")
            title, _ = subject(page)
            if title and result.get("revision"):
                renames.append(("rename_document", {"path": arguments["path"], "name": title + ".pdf",
                                                    "revision": result["revision"]}))
        return calls(renames, number) if renames else text("I could not tell what these documents are.")
    if len(turns) == 3:
        return calls([("list_workspace", {"count": 100})], number)
    if len(turns) == 4:
        groups = {}
        for tab in general(turns[3][0][2]):
            _, group = subject(tab["title"])
            groups.setdefault(group or "Other documents", []).append(tab["path"])
        return calls([("organize_groups", {"command": {"action": "create-group", "name": name,
                                                       "color": COLORS.get(name, "Teal"), "paths": paths}})
                      for name, paths in groups.items()], number)
    if len(turns) == 5:
        return calls([("list_workspace", {"count": 100, "groupID": "general"})], number)
    renamed, kept, failed = [], [], []
    for name, arguments, result in turns[2]:
        if result.get("error"):
            failed.append(f"{arguments['name']}: {result['error']}")
        elif result.get("fileRenamed") is False:
            kept.append(result.get("tellThePerson", ""))
        else:
            renamed.append(result.get("filename", arguments["name"]))
    made = [f"{arguments['command']['name']} ({len(arguments['command']['paths'])})"
            for _, arguments, result in turns[4] if not result.get("error")]
    left = len(turns[5][0][2].get("tabs", []))
    lines = ["Renamed: " + "; ".join(renamed) + "."]
    lines += kept
    if failed:
        lines.append("Not renamed: " + "; ".join(failed))
    lines.append("Groups: " + ", ".join(made) + ".")
    lines.append("General is empty." if left == 0 else f"General still has {left} documents.")
    return text("\n\n".join(lines))


def save(turns, number):
    if not turns:
        return calls([("list_workspace", {"count": 100})], number)
    read_only = [t for t in turns[0][0][2].get("tabs", []) if t.get("readOnly")]
    if len(turns) == 1:
        if not read_only:
            return text("No open document is read-only.")
        return calls([("read_pages", {"path": t["path"], "page": 1, "count": 1}) for t in read_only], number)
    if len(turns) == 2:
        titles = {t["path"]: t["title"] for t in read_only}
        return calls([("document_job", {"path": arguments["path"], "kind": "export-pdf",
                                        "name": titles[arguments["path"]] + ".pdf", "revision": result.get("revision", "")})
                      for _, arguments, result in turns[1]], number)
    done = [r.get("filename") for _, _, r in turns[2] if r.get("completed")]
    failed = [r.get("error") for _, _, r in turns[2] if r.get("error")]
    return text(("Saved to Downloads: " + "; ".join(done) + ". " if done else "") +
                ("Failed: " + "; ".join(failed) if failed else ""))


def answer(messages, tools, number):
    if not tools:
        return text("Document names")  # the chat's title
    question, turns = steps(messages)
    if "uuid" in question:
        return sort(turns, number)
    if "read-only" in question:
        return save(turns, number)
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
            log.write(json.dumps({"tools": tools, "last": request["messages"][-1], "reply": message}) + "\n")
        self.reply({"id": f"stub-{Handler.counter}", "object": "chat.completion", "model": "e2e/stub-model",
                    "choices": [{"index": 0, "message": message,
                                 "finish_reason": "tool_calls" if "tool_calls" in message else "stop"}],
                    "usage": {"prompt_tokens": 1000, "completion_tokens": 100, "total_tokens": 1100}})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()
