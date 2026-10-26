"""The owner's long requests (run_e2e.py --scenario long): the test profile's documents and questions, and the checks.

Sixteen one-page PDFs open in General, fourteen of them named by a UUID as the owner's were, one of those read-only;
a private note already in the test Downloads folder that the assistant must never read. The questions are the owner's
own words from the chat that ended on "The assistant tried to take too many steps at once. Try again."
"""
import json
import os
import uuid

KINDS = [
    "MSK12C02 toggle switch datasheet", "LTE-C9901 IR emitter and detector datasheet",
    "B45D7HA DC fan datasheet", "GDL6150 fingerprint sensor datasheet", "OV50X camera module specification",
    "OV50Q40 camera diffuser review", "Camera module COB drawing", "Mothership antenna placement note",
    "Mothership ICD block diagram", "Mothership carrier inspection report", "LED strip project notes",
    "LED strip wiring notes", "USB PCB final inspection datasheet", "Camera lens shading review",
    "Mothership power tree", "LED strip bill of materials",
]


def one_page_pdf(line):
    content = f"BT /F1 12 Tf 20 60 Td ({line}) Tj ET".encode()
    objects = [b"<</Type/Catalog/Pages 2 0 R>>", b"<</Type/Pages/Kids[3 0 R]/Count 1>>",
               b"<</Type/Page/Parent 2 0 R/MediaBox[0 0 400 120]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>",
               b"<</Length %d>>stream\n" % len(content) + content + b"\nendstream",
               b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>"]
    out, offsets = bytearray(b"%PDF-1.4\n"), []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj" % number + body + b"endobj\n"
    xref = len(out)
    out += b"xref\n0 6\n0000000000 65535 f \n" + b"".join(b"%010d 00000 n \n" % o for o in offsets)
    out += b"trailer<</Size 6/Root 1 0 R>>\nstartxref\n%d\n%%%%EOF\n" % xref
    return bytes(out)


def prepare(work, state):
    folder = os.path.join(work, "general")
    os.makedirs(folder)
    documents = []
    for index, line in enumerate(KINDS):
        name = (uuid.uuid4().hex if index < 14 else line.replace(" ", "-")) + ".pdf"
        path = os.path.join(folder, name)
        with open(path, "wb") as f:
            f.write(one_page_pdf(line))
        documents.append(path)
    os.chmod(documents[1], 0o444)  # LTE-C9901, read-only like the owner's
    downloads = os.path.join(state, "Downloads")
    os.makedirs(downloads)
    with open(os.path.join(downloads, "private-note.txt"), "w") as f:
        f.write("PRIVATE-NOTE-5512 not for the assistant\n")
    questions = {
        "sort": "sort all documents in the “general” group into groups that make sense. The general group must "
                "be empty in the end",
        "uuids": "still UUIDs",
        "reports": "Save a CSV of the renamed documents in Downloads under Reports, run it twice, and also try to "
                   f"list {downloads}",
        "slow": "slow: summarize what we did today",
        "other": "From another chat, read %@ with Python.",
    }
    return {"scenario": "long", "documents": documents, "questions": questions}


def verify(check, out, state, result):
    checks = []
    sort = result.get("sort", {})
    tools = sort.get("tools", [])
    stub = [json.loads(line) for line in open(os.path.join(os.path.dirname(out), "stub.log"))]
    batch = max((len(entry["reply"].get("tool_calls") or []) for entry in stub), default=0)
    check(checks, "one reply with 16 actions runs all of them", batch >= 16 and sum('"pages"' in t for t in tools) >= 16,
          f"largest reply {batch}")
    told = [e for e in stub if e["last"]["role"] == "system" and "has failed" in e["last"]["content"]]
    check(checks, "a call failing again and again is pointed out to the model, which changes approach",
          told and "General now holds 0 documents" in sort.get("answer", ""), sort.get("answer", "")[:300])
    check(checks, "sorting completes with no error", sort.get("state") == 3 and not sort.get("status"),
          sort.get("status", ""))
    uuids = result.get("uuids", {})
    renamed = sum("documentsNoLongerAvailable" in t for t in uuids.get("tools", []))
    check(checks, "renames run in one reply", renamed >= 13, str(renamed))
    check(checks, "a runaway ends in an answer saying what is left, with Continue",
          uuids.get("state") == 6 and uuids.get("canContinue") and "Left:" in uuids.get("answer", "")
          and "Continue" in uuids.get("status", "") and "Try again" not in uuids.get("status", ""),
          json.dumps({k: uuids.get(k) for k in ("state", "canContinue", "status", "answer")})[:400])
    every = " ".join(str(v.get("status", "")) for v in result.values() if isinstance(v, dict))
    check(checks, "no internal limit or Try again is ever shown",
          not any(w in every for w in ("too many steps", "step limit", "malformed", "Try again")), every[:300])
    continued = result.get("continued", {})
    originals = os.path.join(state, "Downloads", "Read-only originals")
    kept = os.listdir(originals) if os.path.isdir(originals) else []
    check(checks, "Continue resumes and finishes: the read-only original saved under its name in Downloads",
          continued.get("state") == 3 and any(n.startswith("LTE-C9901") for n in kept)
          and "Saved the read-only original" in continued.get("answer", ""), str(kept))
    check(checks, "sending from the top of the chat shows its end; Continue too",
          result.get("uuids_sent_at_end") and result.get("continue_at_end") and result.get("reports_sent_at_end"))
    reports = result.get("reports", {})
    printed = reports.get("answer", "")
    folder = os.path.join(state, "Downloads", "Reports")
    names = sorted(os.listdir(folder)) if os.path.isdir(folder) else []
    check(checks, "Python saves into Downloads/Reports, never over a file", names == ["renamed 2.csv", "renamed.csv"],
          str(names))
    check(checks, "Python can't list Downloads or read a file there",
          "REFUSED LIST" in printed and "REFUSED READ" in printed and "PRIVATE-NOTE" not in printed
          and "LEAK" not in printed, printed[:400])
    check(checks, "this chat reads back the file it saved", "READ BACK" in printed and "document,new name" in printed)
    cards = [a["name"] for c in reports.get("activity", []) if c.get("cardKind") == "assistant.output"
             for a in c.get("attachments", [])]
    check(checks, "each saved file has a card with Open and Show in Finder",
          "renamed.csv" in cards and "renamed 2.csv" in cards, str(cards))
    other = result.get("other", {})
    check(checks, "another chat can't read it", "not attached to this chat" in other.get("answer", ""),
          other.get("answer", "")[:300])
    check(checks, "scrolled up during a reply: Jump to latest, then New message",
          result.get("pill_while_running") == "Jump to latest ↓" and result.get("pill_after_reply") == "New message ↓"
          and result.get("stayed_up"), json.dumps({k: result.get(k) for k in ("pill_while_running",
                                                                               "pill_after_reply", "stayed_up")}))
    check(checks, "the pill scrolls to the new message and goes", result.get("pill_after_click") == "")
    return checks
