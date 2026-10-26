"""The owner's long requests, replayed by the model stub (model_stub.py) through the app's real tools.

On 26 October the owner asked the assistant to sort the documents in the General group into groups, then to rename the
ones still named by a UUID ("still UUIDs"), then to save the read-only ones in Downloads. The chat ended on "The
assistant tried to take too many steps at once. Try again." This plays a model that works the way that one did:

- sort: list the workspace, read every General document in one reply (16 actions), make the groups in one reply, then
  repeat one failing call until the app points the loop out, and then change approach and finish;
- still UUIDs: read and rename every UUID-named document in one reply each, then retry the read-only one's rename
  again and again whatever it is told (a runaway), until the app winds the request up; it then says what is left;
- Continue: carries on from there, saving the read-only original under its proper name in Downloads, and finishes;
- Reports: Python saves a CSV in Downloads/Reports, twice, tries to list Downloads and read a file there, and reads
  its own file back by id; another chat asks for that id;
- slow: answers after a few seconds, so the driver can scroll up while it waits.
"""
import json
import re
import time

MARKS = ("general", "still UUIDs", "Continue: carry on", "Reports", "From another chat", "slow")
UUID = re.compile(r"^[0-9a-f]{32}$")


def call_batch(calls, number):
    return {"role": "assistant", "content": "", "tool_calls": [
        {"id": f"stub-{number}-{index}", "type": "function", "function": {"name": name, "arguments": json.dumps(args)}}
        for index, (name, args) in enumerate(calls)]}


def text(content):
    return {"role": "assistant", "content": content}


def this_request(messages):
    """The tool calls and results since the person's last message, oldest first: [(name, args, result)]."""
    start = max(i for i, m in enumerate(messages) if m["role"] == "user")
    calls, results = {}, []
    for message in messages[start + 1:]:
        for call in message.get("tool_calls") or []:
            calls[call["id"]] = (call["function"]["name"], json.loads(call["function"]["arguments"] or "{}"))
        if message["role"] == "tool" and message["tool_call_id"] in calls:
            try:
                result = json.loads(message["content"])
            except ValueError:
                result = {"error": message["content"]}
            results.append(calls[message["tool_call_id"]] + (result,))
    return results


def told_of_loop(messages):
    return any(m["role"] == "system" and i and "has failed" in m["content"] for i, m in enumerate(messages))


def latest(results, name):
    for tool, args, result in reversed(results):
        if tool == name:
            return args, result
    return None, None


def general_tabs(workspace):
    general = {g["id"] for g in workspace.get("groups", []) if g.get("general")}
    return [t for t in workspace.get("tabs", []) if t.get("groupID") in general or not t.get("groupID")]


def first_text(result):
    pages = result.get("pages") or [{}]
    return " ".join((pages[0].get("text") or "").split())


def category(words):
    lower = words.lower()
    for key, group, color in (("datasheet", "Datasheets", "Slate"), ("camera", "Camera Module Specs", "Plum"),
                              ("mothership", "Mothership Documentation", "Rose")):
        if key in lower:
            return group, color
    return "LED Strip Notes", "Amber"


def sort_general(messages, results, number):
    _, workspace = latest(results, "list_workspace")
    if workspace is None:
        return call_batch([("list_workspace", {"count": 100})], number)
    reads = [r for r in results if r[0] == "read_pages"]
    tabs = general_tabs(workspace)
    if not reads and tabs:  # every General document at once: more than the 12 actions a reply used to allow
        return call_batch([("read_pages", {"path": t["path"], "page": 1, "count": 1}) for t in tabs], number)
    if not any(r[0] == "organize_groups" for r in results):
        groups = {}
        for _, args, result in reads:
            groups.setdefault(category(first_text(result)), []).append(args["path"])
        return call_batch([("organize_groups", {"command": {"action": "create-group", "name": name, "color": color,
                                                            "paths": paths}})
                           for (name, color), paths in sorted(groups.items())], number)
    since = results[[r[0] for r in results].index("organize_groups"):]
    if not any(r[0] == "list_workspace" for r in since):
        if told_of_loop(messages):  # told it keeps failing: change approach, check the result instead
            return call_batch([("list_workspace", {"count": 100})], number)
        # The loop: the same move into a group that doesn't exist, again and again.
        first = reads[0][1]["path"]
        return call_batch([("organize_groups", {"command": {"action": "move-tab", "groupID": "general-misc",
                                                            "path": first}})], number)
    left = len(general_tabs(workspace))
    return text(f"Sorted the General documents into groups by what they are. General now holds {left} documents. "
                "Moving into a group that doesn't exist kept failing, so I made the groups directly instead.")


def proper_name(words):
    return re.sub(r"[^A-Za-z0-9 .\-]", "", words)[:60].strip() + ".pdf"


def rename_uuids(messages, tools, results, number):
    if not tools:  # the app wound the request up: say what was done and what is left
        renamed = [r for r in results if r[0] == "rename_document" and "error" not in r[2]]
        stuck = {r[1]["path"] for r in results if r[0] == "rename_document" and "error" in r[2]}
        return text(f"- Renamed {len(renamed)} documents that were named by a UUID.\n"
                    f"- Left: {len(stuck)} read-only document still has its UUID name; renaming it needs a copy.")
    _, workspace = latest(results, "list_workspace")
    if workspace is None:
        return call_batch([("list_workspace", {"count": 100})], number)
    uuids = [t for t in workspace.get("tabs", []) if UUID.match(t.get("title", ""))]
    reads = [r for r in results if r[0] == "read_pages"]
    if not reads:
        return call_batch([("read_pages", {"path": t["path"], "page": 1, "count": 1}) for t in uuids], number)
    renames = [r for r in results if r[0] == "rename_document"]
    if not renames:  # one reply renaming them all
        return call_batch([("rename_document", {"path": args["path"], "name": proper_name(first_text(result)),
                                                "revision": result.get("revision", "")})
                           for _, args, result in reads if "error" not in result], number)
    failed = [r for r in renames if "error" in r[2]]
    if failed:  # the runaway: the read-only one again, whatever the app says
        return call_batch([("rename_document", failed[-1][1])], number)
    return text("Renamed every document that was named by a UUID.")


def continue_after_pause(messages, results, number):
    saved = [r for r in results if r[0] == "save_file"]
    if saved:
        result = saved[-1][2]
        return text(f"Saved the read-only original as {result.get('saved_as')} in {result.get('folder')}; the "
                    "original stays in Collection. Every document now has a proper name.")
    for message in reversed(messages):
        for call in message.get("tool_calls") or []:
            args = json.loads(call["function"]["arguments"] or "{}")
            if call["function"]["name"] == "rename_document" and args.get("path"):
                return call_batch([("save_file", {"document": args["path"], "name": args["name"],
                                                  "folder": "Read-only originals"})], number)
    return text("Nothing was left to do.")


REPORT = r'''
import os
downloads = %r
for label, attempt in (("LIST", lambda: os.listdir(downloads)),
                       ("READ", lambda: open(os.path.join(downloads, "private-note.txt")).read())):
    try:
        print("LEAK", label, attempt())
    except Exception as error:
        print("REFUSED", label, type(error).__name__)
os.makedirs("out/Reports", exist_ok=True)
open("out/Reports/renamed.csv", "w").write("document,new name\nfan,Fan datasheet.pdf\n")
'''

READ_BACK = r'''
import json
for doc in json.load(open("documents/index.json"))["documents"]:
    print("READ BACK", doc["title"], open(doc["file"]).read().splitlines()[0])
'''


def reports(question, results, number):
    downloads = re.search(r"try to list (/\S+?)\.?$", question.strip()).group(1)
    runs = [r for r in results if r[0] == "run_python"]
    if len(runs) < 2:
        return call_batch([("run_python", {"code": REPORT % downloads})], number)
    if len(runs) == 2:
        kept = (runs[0][2].get("out") or [{}])[0]
        return call_batch([("run_python", {"code": READ_BACK, "documents": [{"id": kept.get("id", "none")}]})],
                          number)
    names = [o.get("saved_as") for _, _, r in runs[:2] for o in r.get("out", [])]
    return text("Saved " + " and ".join(map(str, names)) + " in Downloads/Reports. Python printed:\n\n```\n"
                + "".join(r.get("stdout", r.get("error", "")) for _, _, r in runs) + "```")


def answer(messages, tools, number):
    users = [m for m in messages if m["role"] == "user"]
    question = users[-1]["content"]
    results = this_request(messages)
    if "slow" in question:
        time.sleep(5)
        return text("Here is the summary you asked for, after a long think.")
    if "From another chat" in question:
        if not results:
            identifier = re.search(r"attachment:saved-[0-9a-f]+", question).group(0)
            return call_batch([("run_python", {"code": READ_BACK, "documents": [{"id": identifier}]})], number)
        return text("That didn't work: " + results[-1][2].get("error", "no error"))
    if "Continue: carry on" in question:
        return continue_after_pause(messages, results, number)
    if "still UUIDs" in question:
        return rename_uuids(messages, tools, results, number)
    if "Reports" in question:
        return reports(question, results, number)
    return sort_general(messages, results, number)
