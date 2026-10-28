#!/usr/bin/env python3
"""Every tab group palette, pictured through the real app, off screen, and put side by side.

usage: palette_reel.py --app <ShenzhenPDF.app> --work <new folder> [--out <folder>]

A copy of the app (its own bundle identifier, LSUIElement, ad hoc signed) runs once from --work with a test profile
(SPDF_STATE_DIR and a home of its own), tools/updater-e2e/szut.m keeping every window off screen and the app offline.
palette_driver.m opens one wide reader window with ten named groups in hue order (one open with four documents) plus
General, a PDF page in the reader and the sidebar open, then picks each palette in Settings › Appearance › Tab group
colors and pictures the window at 2x in light and dark. No rebuild per palette: the app switches them at runtime.

Into --out (default <work>/reel): every picture, palette-reel-light.png and palette-reel-dark.png (each palette's
picture cropped to the window's top half, stacked and labelled), and palette-slideshow.mp4 (each palette for two
seconds, light then dark, named). Needs Pillow and reportlab for Python, and ffmpeg. Checks print PASS/FAIL: each
palette was chosen, and every group's chip shows the colour SPDFMacTabGroups.mm works out for it.
"""
import argparse
import colorsys
import json
import os
import shutil
import signal
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from run_e2e import AI_SETTINGS, NODIALOGS, SZUT, build, fixtures, prepare_app  # noqa: E402

PALETTES = ["Neon", "Coolors vivid", "Coolors pastel rainbow", "Cyberpunk", "Pastel", "Pastel but vibrant",
            "Apple system", "Codex"]
# Base colours, as in SPDFMacTabGroups.mm, in hue order: Coral, Orange, Amber, Green, Slate, Teal, Blue, Indigo,
# Purple, Plum, Rose. Used only to check the pictures.
HUES = ["Coral", "Orange", "Amber", "Green", "Slate", "Teal", "Blue", "Indigo", "Purple", "Plum", "Rose"]
BASES = {
    "Neon": "ff3131 ff8c00 fff200 39ff14 00ff9f 00f0ff 2d7dff 4d2bff b026ff ff2bd6 ff4f9a",
    "Coolors vivid": "f42a45 ff6b00 ffc445 f0f000 00e65e 00a695 00a695 c2add9 cf6dcf c961a5 d17b92",
    "Coolors pastel rainbow": "ffadad ffd6a5 fdffb6 caffbf 9bf6ff 9bf6ff a0c4ff bdb2ff ffc6ff ffc6ff ffadad",
    "Cyberpunk": "ff003c f5a524 fcee0a fcee0a 0abdc6 00f0ff 05d9e8 7b61ff 9d4edd ea00d9 ff2a6d",
    "Pastel": "fec89a ffe5a8 b5e48c 99d98c 99d98c bde0fe a2d2ff cdb4db cdb4db ffc8dd ffafcc",
    "Pastel but vibrant": "ffa8a8 ffa94d ffd43b 69db7c 63e6be 38d9a9 4dabf7 748ffc b197fc be4bdb e64980",
    "Apple system": "ff3b30 ff9500 ffcc00 34c759 2ed3b7 32ade6 007aff 5856d6 af52de af52de ff2d55",
    "Codex": "e1292f f76b15 ffc205 2fb26a 59779a 0ea5b0 1a6ae6 4f46e5 a03ae0 d01fb0 e11969",
}
# The owner's group names, in hue order; Indigo is left out to keep to ten.
GROUPS = [("Remote Design", "Coral"), ("Remote Parts", "Orange"), ("USB vertical", "Amber"), ("Carrier PCB", "Green"),
          ("Image Comparisons", "Slate"), ("Audio Board", "Teal"), ("Camera Module Specs", "Blue"),
          ("Mothership and Carrier", "Purple"), ("Antenna", "Plum"), ("Sourcing", "Rose")]
SETTINGS = ("version: 1\nshowShortcutHelpOnLaunch: false\nautoUpdateEnabled: false\ndefaultReaderPromptDismissed: true\n"
            "fullDiskAccessPromptDismissed: true\npermissionsWizardShown: true\ndefaultSidebarVisibleForNewDocuments: "
            "true\ndefaultMinimapVisibleForNewDocuments: false\nfitMode: 4\nsettingsExperienceVersion: 99\n")


def worked_fill(base):
    """SPDFMacTabGroups.mm's fill: deepened in HSL lightness until white reads 4.5:1, when white already reads 2.6:1."""
    def lum(h):
        f = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
        f = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in f]
        return 0.2126 * f[0] + 0.7152 * f[1] + 0.0722 * f[2]

    def white(h):
        return 1.05 / (lum(h) + 0.05)
    if white(base) < 2.6:
        return base
    h, light, s = colorsys.rgb_to_hls(*[int(base[i:i + 2], 16) / 255 for i in (0, 2, 4)])
    fill = base
    while white(fill) < 4.5:
        light -= 0.01
        fill = "%02x%02x%02x" % tuple(round(max(0, min(1, c)) * 255) for c in colorsys.hls_to_rgb(h, light, s))
    return fill


def spec_pdf(path):
    """A two-page hardware specification with chapters, so the reader and its sidebar have something real to show."""
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import getSampleStyleSheet
    from reportlab.lib import colors
    from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak

    styles = getSampleStyleSheet()

    class Doc(SimpleDocTemplate):
        def afterFlowable(self, flowable):
            if isinstance(flowable, Paragraph) and flowable.style.name in ("Heading1", "Heading2"):
                key = "h%d" % id(flowable)
                self.canv.bookmarkPage(key)
                self.canv.addOutlineEntry(flowable.getPlainText(), key, level=int(flowable.style.name[-1]) - 1)

    body = [Paragraph("Remote board: hardware specification", styles["Heading1"]),
            Paragraph("Revision C. The remote board carries the camera module and the audio front end, and joins the "
                      "carrier PCB through a 24-pin FPC.", styles["BodyText"]), Spacer(1, 10)]
    sections = [("Connector", "24-pin FPC, 0.5 mm pitch, bottom contact. Pins 1 and 24 are ground; the shield ties to "
                 "the flex tail at both ends."),
                ("Power", "Two rails from the carrier: 3.3 V at up to 600 mA and 1.8 V at up to 250 mA. Both rails "
                 "have a 10 uF bulk capacitor at the connector."),
                ("Audio lines", "Two differential pairs, routed on layer 3 with 100 ohm impedance and length matched "
                 "to 0.1 mm."),
                ("Camera interface", "MIPI CSI-2, two lanes, up to 1.5 Gb/s per lane. The clock pair runs between "
                 "the data pairs.")]
    for title, text in sections:
        body += [Paragraph(title, styles["Heading2"]), Paragraph(text, styles["BodyText"]), Spacer(1, 6)]
    table = Table([["Item", "Owner", "Due"], ["Pin map", "Audio", "Friday"], ["Shield", "Mechanical", "Next week"],
                   ["Second source", "Sourcing", "November"]], colWidths=[140, 120, 100])
    table.setStyle(TableStyle([("GRID", (0, 0), (-1, -1), 0.5, colors.grey),
                               ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#eeeeee"))]))
    body += [Paragraph("Open items", styles["Heading2"]), table, PageBreak(),
             Paragraph("Test plan", styles["Heading1"]),
             Paragraph("Each board is tested on the bench fixture before it is fitted to the carrier.",
                       styles["BodyText"])]
    Doc(path, pagesize=A4, title="Remote board specification").build(body)


def make_documents(folder):
    os.makedirs(folder, exist_ok=True)
    names = ["Remote spec.pdf", "Design notes.md", "Flex drawing.pdf", "Remote BOM.pdf",
             "Connector shortlist.pdf", "USB vertical drawing.pdf", "Carrier PCB rev B.pdf", "Image comparison.pdf",
             "Audio board BOM.pdf", "Camera module specs.pdf", "Mothership layout.pdf", "Antenna report.pdf",
             "Supplier quotes.pdf", "Meeting notes.pdf", "Shipping checklist.pdf"]
    paths = []
    for n, name in enumerate(names):
        path = os.path.join(folder, name)
        if n == 0:
            spec_pdf(path)
        elif name.endswith(".md"):
            with open(path, "w") as f:
                f.write("# Remote design notes\n\n## Connector\n\n24-pin FPC.\n")
        else:
            fixtures.write_pdf(path, 2 + n % 3, label=name[:-4])
        paths.append(path)
    return paths


def compose(out, result):
    from PIL import Image, ImageDraw, ImageFont
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 52)
    small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 64)
    entries = result["palettes"]
    for look in ("light", "dark"):
        bg, fg = ((255, 255, 255), (17, 17, 17)) if look == "light" else ((24, 24, 24), (238, 238, 238))
        crops = []
        for entry in entries:
            im = Image.open(entry[look]).convert("RGB")
            crops.append(im.crop((0, 0, im.width, im.height // 2)))
        band, gap = 96, 28
        width = max(c.width for c in crops)
        sheet = Image.new("RGB", (width, sum(c.height + band + gap for c in crops)), bg)
        draw, y = ImageDraw.Draw(sheet), 0
        for entry, crop in zip(entries, crops):
            draw.text((40, y + 22), entry["name"], font=font, fill=fg)
            y += band
            sheet.paste(crop, (0, y))
            y += crop.height + gap
        sheet.save(os.path.join(out, f"palette-reel-{look}.png"))
    frames = os.path.join(out, "frames")
    os.makedirs(frames, exist_ok=True)
    n = 0
    for look in ("light", "dark"):
        for entry in entries:
            im = Image.open(entry[look]).convert("RGB")
            im = im.resize((1920, round(im.height * 1920 / im.width / 2) * 2), Image.LANCZOS)
            draw = ImageDraw.Draw(im, "RGBA")
            label = f"{entry['name']}  ·  {look}"
            box = draw.textbbox((0, 0), label, font=small)
            x, y = (im.width - box[2]) // 2, im.height - box[3] - 90
            draw.rounded_rectangle((x - 36, y - 24, x + box[2] + 36, y + box[3] + 30), 24, fill=(0, 0, 0, 190))
            draw.text((x, y), label, font=small, fill=(255, 255, 255))
            im.save(os.path.join(frames, "%02d.png" % n))
            n += 1
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "0.5", "-i", os.path.join(frames, "%02d.png"),
                    "-c:v", "libx264", "-r", "30", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                    os.path.join(out, "palette-slideshow.mp4")], check=True)
    shutil.rmtree(frames)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--out")
    args = parser.parse_args()
    work = os.path.abspath(args.work)
    os.makedirs(work)
    out = os.path.abspath(args.out or os.path.join(work, "reel"))
    pictures, home, state = (os.path.join(work, n) for n in ("pictures", "home", "state"))
    for folder in (pictures, home, state):
        os.makedirs(folder)
    with open(os.path.join(state, "settings.yaml"), "w") as f:
        f.write(SETTINGS)
    with open(os.path.join(state, "ai-settings.yaml"), "w") as f:
        f.write(AI_SETTINGS)
    app = prepare_app(args.app, work)
    build(SZUT, os.path.join(work, "szut.dylib"), "AppKit", "CoreServices", "Security")
    build(os.path.join(HERE, "palette_driver.m"), os.path.join(work, "driver.dylib"), "AppKit", "QuartzCore")
    documents_dir = os.path.join(os.path.expanduser("~/Library/Caches/shenzhen-build/palette-reel"),
                                 os.path.basename(work))
    documents = make_documents(documents_dir)
    groups = [{"name": "Remote Design", "color": "Coral", "documents": documents[0:4]}]
    groups += [{"name": n, "color": c, "documents": [documents[3 + i]]} for i, (n, c) in enumerate(GROUPS) if i]
    plan = {"documents": documents, "groups": groups, "open_group": "Remote Design", "selected": documents[0],
            "palettes": PALETTES, "width": 1820, "height": 1080}
    with open(os.path.join(work, "plan.json"), "w") as f:
        json.dump(plan, f)
    with open(os.path.join(work, "routes.json"), "w") as f:
        f.write("{}")
    env = {"PATH": "/usr/bin:/bin", "HOME": home, "CFFIXED_USER_HOME": home, "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "SPDF_STATE_DIR": state, "SZFRIENDS_STATE_DIR": state, "SPDF_NO_ACTIVATE": "1", "SZUT_ROOT": work,
           "SZUT_LOG": os.path.join(work, "szut.jsonl"), "SZUT_ROUTES": os.path.join(work, "routes.json"),
           "DYLD_INSERT_LIBRARIES": os.path.join(work, "szut.dylib") + ":" + os.path.join(work, "driver.dylib"),
           "SPDF_E2E_PLAN": os.path.join(work, "plan.json"), "SPDF_E2E_OUT": pictures}
    try:
        with open(os.path.join(work, "app.log"), "w") as log:
            process = subprocess.Popen([os.path.join(app, "Contents", "MacOS", "ShenzhenPDF")], env=env, stdout=log,
                                       stderr=subprocess.STDOUT)
            try:
                process.wait(timeout=300)
            except subprocess.TimeoutExpired:
                print("FAIL the app did not finish within 5 minutes")
            finally:
                if process.poll() is None:
                    os.kill(process.pid, signal.SIGKILL)
                    process.wait()
    finally:
        subprocess.run([sys.executable, NODIALOGS, "unregister", work])
        shutil.rmtree(documents_dir, ignore_errors=True)
    result_file = os.path.join(pictures, "result.json")
    result = json.load(open(result_file)) if os.path.exists(result_file) else {"palettes": []}
    checks = []

    def check(name, condition, detail=""):
        checks.append(condition)
        print(("PASS " if condition else "FAIL ") + name + (f" ({detail})" if detail and not condition else ""))

    from PIL import Image
    check("every palette was pictured", [e["name"] for e in result["palettes"]] == PALETTES,
          str([e["name"] for e in result["palettes"]]))
    height = result.get("frame", [0, 0])[1]
    for entry in result["palettes"]:
        check(f"{entry['name']}: chosen in Settings › Appearance", entry.get("chosen"))
        bases = dict(zip(HUES, BASES[entry["name"]].split()))
        im = Image.open(entry["light"]).convert("RGB")
        wrong = []
        for header in entry["headers"]:
            if header["color"] not in bases:
                continue
            x, y, w, h = header["rect"]
            # A point inside the chip, left of its title: in the picture, 2x and from the top.
            px, py = round((x + 4) * 2), round((height - (y + h / 2)) * 2)
            seen = "%02x%02x%02x" % im.getpixel((px, py))
            want = worked_fill(bases[header["color"]])
            if max(abs(int(seen[i:i + 2], 16) - int(want[i:i + 2], 16)) for i in (0, 2, 4)) > 3:
                wrong.append(f"{header['name']} {seen} not {want}")
        check(f"{entry['name']}: every chip shows its worked-out colour", not wrong, "; ".join(wrong))
    if result["palettes"]:
        os.makedirs(out, exist_ok=True)
        for entry in result["palettes"]:
            for look in ("light", "dark"):
                shutil.copy(entry[look], out)
        for look in ("light", "dark"):
            settings = os.path.join(pictures, f"settings-appearance-{look}.png")
            if os.path.exists(settings):
                shutil.copy(settings, out)
        compose(out, result)
    print(f"{sum(checks)} of {len(checks)} checks passed; reel in {out}")
    return 0 if all(checks) else 1


if __name__ == "__main__":
    sys.exit(main())
