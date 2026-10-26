#!/usr/bin/env python3
"""A stand-in for the assistant's model, for the offscreen end-to-end test (run_e2e.py).

It answers OpenRouter's chat completions API on 127.0.0.1 only, the way a model that follows the system prompt would:
it reads the ids the app gives it (the open document's doc: id, the chat's attachment: ids), calls the app's real tools
with them (run_python, read_attachment, run_subagents), and answers with what those tools returned. Everything the
person sees as a result (numbers, files, refusals) comes from the app's real tools; this only chooses the calls.

Usage: model_stub.py <port file> <log file>
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# The code the "assistant" runs. It measures the plates the app extracted: no pixels come from anywhere else.
MEASURE = r'''
import json
import numpy as np
from PIL import Image, ImageFilter

def fit(xs, ys):
    a = np.c_[2 * xs, 2 * ys, np.ones_like(xs)]
    c = np.linalg.lstsq(a, xs * xs + ys * ys, rcond=None)[0]
    return c[0], c[1], np.sqrt(c[2] + c[0] ** 2 + c[1] ** 2)

def scene_circle(gray):
    # The scene's edge: along rays from the centre, where brightness falls most steeply; a circle fitted to it.
    k = 4
    small = np.asarray(Image.fromarray(gray.astype(np.uint8)).resize((gray.shape[1] // k, gray.shape[0] // k),
                                                                   Image.BOX).filter(ImageFilter.GaussianBlur(2)), float)
    h, w = small.shape
    cx, cy = w / 2, h / 2
    radii = np.arange(min(h, w) * 0.25, min(h, w) * 0.62, 0.5)
    angles = np.linspace(0, 2 * np.pi, 720, endpoint=False)
    for _ in range(4):
        xs = cx + np.cos(angles)[:, None] * radii
        ys = cy + np.sin(angles)[:, None] * radii
        inside = (xs >= 0) & (xs < w - 1) & (ys >= 0) & (ys < h - 1)
        profile = small[np.clip(ys.astype(int), 0, h - 1), np.clip(xs.astype(int), 0, w - 1)]
        step = np.where(inside[:, 1:] & inside[:, :-1], np.diff(profile, axis=1), 0)
        edge = np.argmin(step, axis=1)
        valid = inside[np.arange(len(angles)), edge]
        ex, ey = (cx + np.cos(angles) * radii[edge])[valid], (cy + np.sin(angles) * radii[edge])[valid]
        fx, fy, fr = fit(ex, ey)
        off = np.abs(np.hypot(ex - fx, ey - fy) - fr)
        keep = off < 3 * np.median(off) + 1
        cx, cy, r = fit(ex[keep], ey[keep])
    return cx * k, cy * k, r * k

def measure(path):
    rgb = np.asarray(Image.open(path).convert("RGB"))
    gray = 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]
    cx, cy, radius = scene_circle(gray)
    half = radius / np.sqrt(2)
    square = gray[int(round(cy - half)):int(round(cy + half)), int(round(cx - half)):int(round(cx + half))]
    return {"width": rgb.shape[1], "height": rgb.shape[0], "center": [round(cx, 1), round(cy, 1)],
            "radius_px": round(radius, 1), "square_px": square.shape[1],
            "mean_gray_percent": round(float(square.mean()) / 255 * 100, 3)}

index = json.load(open("documents/index.json"))["documents"][0]
results = {}
for image in index["images"]:
    if image["page"] in (4, 5) and str(image["page"]) not in results:
        results[str(image["page"])] = dict(measure(image["file"]), lossless=image["lossless"], file=image["file"])
print(json.dumps(results))
'''

OUTPUTS = MEASURE + r'''
import csv
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages
labels = {"4": "IR 10% (p. 4)", "5": "IR 100% (p. 5)"}
with open("out/diffuser_gray.csv", "w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["page", "condition", "mean_gray_percent", "square_px", "radius_px"])
    for page, r in sorted(results.items()):
        writer.writerow([page, labels[page], r["mean_gray_percent"], r["square_px"], r["radius_px"]])
figure, axes = plt.subplots(figsize=(6, 4))
values = [results[p]["mean_gray_percent"] for p in ("4", "5")]
axes.bar([labels["4"], labels["5"]], values, color=["#6b7a8f", "#d9a441"])
for x, v in enumerate(values): axes.text(x, v + 0.5, f"{v:.2f} %", ha="center")
axes.set_ylabel("Mean gray, % of full scale"); axes.set_title("Square inscribed in the diffuser scene")
figure.tight_layout(); figure.savefig("out/diffuser_gray.png", dpi=120)
with PdfPages("out/diffuser_gray_report.pdf") as pdf:
    pdf.savefig(figure)
    page = plt.figure(figsize=(6, 4)); page.text(0.05, 0.9, "Diffuser plates, mean gray", size=14)
    for i, (p, r) in enumerate(sorted(results.items())):
        page.text(0.05, 0.75 - i * 0.1, f"{labels[p]}: {r['mean_gray_percent']:.3f} % ({r['square_px']} px square)")
    pdf.savefig(page)
print("saved")
'''

ATTACHMENTS = r'''
import hashlib, json, os
sibling = %r
for doc in json.load(open("documents/index.json"))["documents"]:
    path = doc["file"]
    if doc.get("kind") == "folder":
        names = sorted(os.path.relpath(os.path.join(d, n), path) for d, _, files in os.walk(path) for n in files)
        print("FOLDER", doc["title"], names)
        continue
    data = open(path, "rb").read()
    print("FILE", doc["title"], len(data), "bytes", data[:5], hashlib.sha256(data).hexdigest()[:12])
for target, read in ((sibling, lambda path: open(path).read(20)), (os.path.dirname(sibling), os.listdir)):
    try:
        found = read(target)
        print("LEAK", target, found)
    except Exception as error:
        print("REFUSED", os.path.basename(target), type(error).__name__)
'''

COUNT = r'''
import json, os
doc = json.load(open("documents/index.json"))["documents"][0]
names = sorted(n for _, _, files in os.walk(doc["file"]) for n in files)
print(len(names), names)
'''


def call(name, arguments, number):
    return {"role": "assistant", "content": "", "tool_calls": [
        {"id": f"stub-{number}", "type": "function", "function": {"name": name, "arguments": json.dumps(arguments)}}]}


def text(content):
    return {"role": "assistant", "content": content}


def answer(messages, tools, number):
    system = messages[0]["content"] if messages and messages[0]["role"] == "system" else ""
    if not tools:
        return text("Diffuser plates: gray levels")
    task = system.startswith("You are one research task")
    users = [m for m in messages if m["role"] == "user"]
    question = users[-1]["content"] if users else ""
    last = messages[-1]
    attachments = re.findall(r"\((file|folder), (attachment:[0-9a-f]+)\)", system)
    if last["role"] == "tool":
        result = json.loads(last["content"])
        if task:
            return text("The folder holds " + result.get("stdout", result.get("error", "")).strip())
        if "tasks" in result:
            return text("The part reported: " + "; ".join(t.get("summary", t.get("problem", ""))
                                                          for t in result["tasks"]))
        if "error" in result:
            return text("That didn't work: " + result["error"])
        if "out" in result:
            kept = ", ".join(f["saved_as"] for f in result["out"] if "saved_as" in f)
            return text(f"Saved to your Downloads folder: {kept}.")
        if "gray" in question.lower():
            values = json.loads(result["stdout"])
            rows = "\n".join(f"| {page} | {r['mean_gray_percent']:.2f} % | {r['square_px']} px |"
                             for page, r in sorted(values.items()))
            return text("Measured on the embedded plates at native resolution:\n\n| Page | Mean gray | Square |\n"
                        "|---|---|---|\n" + rows)
        return text("Python printed:\n\n```\n" + result.get("stdout", "") + "```")
    if task:
        identifier = re.search(r"attachment:[0-9a-f]+", question).group(0)
        return call("run_python", {"code": COUNT, "documents": [{"id": identifier}]}, number)
    document = re.search(r"doc:[0-9a-f]{64}", system)
    lower = question.lower()
    if "csv" in lower:
        return call("run_python", {"code": OUTPUTS, "documents": [
            {"id": document.group(0), "images_on_pages": [4, 5]}]}, number)
    if "gray" in lower:
        return call("run_python", {"code": MEASURE, "documents": [
            {"id": document.group(0), "images_on_pages": [4, 5]}]}, number)
    if "parts" in lower:
        folder = [i for kind, i in attachments if kind == "folder"][0]
        return call("run_subagents", {"tasks": [{"title": "Files in the attached folder", "instructions":
            f"Count the files in the attached folder {folder} with run_python (documents id {folder})."}]}, number)
    if "other chat" in lower:
        identifier = re.search(r"attachment:[0-9a-f]+", question).group(0)
        return call("run_python", {"code": "print(open('documents/index.json').read())",
                                   "documents": [{"id": identifier}]}, number)
    if "attached" in lower:
        sibling = re.search(r"(/\S+sibling\S*)", question).group(1).rstrip(".")
        return call("run_python", {"code": ATTACHMENTS % sibling,
                                   "documents": [{"id": i} for _, i in attachments]}, number)
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
        message = answer(request["messages"], tools, Handler.counter)
        with open(sys.argv[2], "a") as log:
            log.write(json.dumps({"tools": tools, "system": request["messages"][0]["content"][-1500:],
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
