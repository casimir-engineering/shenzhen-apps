#!/usr/bin/env python3
"""Tab hover labels and page thumbnails, through the real app, off screen.

usage: run_e2e.py --app <ShenzhenPDF.app> --work <new folder> [--compare-app <an earlier ShenzhenPDF.app>]

A copy of the app (its own bundle identifier, LSUIElement, ad hoc signed) runs twice from --work with a test profile
(SPDF_STATE_DIR and a home of its own). tools/updater-e2e/szut.m keeps every window off screen and the app offline;
driver.m moves the pointer over the tab bar through the strip's own event handlers and saves pictures.

  first     opens a document, goes to page 5 and turns it clockwise, opens a document with a long name and puts it
            in a group with a long name through the tab menu and the name prompt; hovers the turned tab, the long
            document tab and the group's title tab (expanded, then collapsed), then empty tab bar and outside the
            tab bar, in light and dark; opens a Markdown file, an image and a text file and hovers each next to the
            turned PDF, in light and dark; opens 28 more documents and measures memory and hover time; then moves
            the pointer from a tab onto every kind of empty place in the full tab bar (between tabs, above and below
            one, between groups, between a title tab and its first tab or the "+N" badge, the badges, either end of
            the bar), in light and dark; hovers a tab scrolled half under the "+N" badge; and moves a tab, closes
            one and narrows the window under a pointer that stays put.
  restored  relaunches on that session: 30 tabs, only one shown since launch. Hovers a tab never shown (title
            first, thumbnail rendered from the file and faded in), then waits for the rest to be made in the
            background and measures memory and hover time again. Hovers the Markdown, image and text tabs, never shown:
            their pages come from their files.
  memory-*  with --compare-app: the same restored session left alone for 16 s, this build and the earlier one twice
            each, interleaved: memory and CPU, so what the thumbnails cost shows against the same work without them.

The documents live under ~/Library/Caches/shenzhen-build/tab-hover-e2e/ while the test runs (the reader asks for a
Save As before turning a page of a PDF in a temporary folder) and are removed at the end.

Checks print PASS/FAIL; pictures and result.json are in <work>/<phase>/out. Exit status 1 when a check fails.
"""
import argparse
import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../../../../.."))
SZUT = os.path.join(REPO, "tools/updater-e2e/szut.m")
NODIALOGS = os.path.join(REPO, "tools/updater-e2e/nodialogs.py")
sys.path.insert(0, HERE)
import fixtures  # noqa: E402

GROUP = "Supplier quotes, samples and test reports for the camera flex, revision C"
SETTINGS = ("version: 1\nshowShortcutHelpOnLaunch: false\nautoUpdateEnabled: false\ndefaultReaderPromptDismissed: true\n"
            "fullDiskAccessPromptDismissed: true\npermissionsWizardShown: true\nfriends:\n  enabled: false\n"
            "  settingsIntroduced: 1\n")


def build(source, output, *frameworks):
    command = ["clang", "-dynamiclib", "-fobjc-arc", "-arch", "arm64", source, "-o", output]
    for framework in frameworks:
        command += ["-framework", framework]
    subprocess.run(command, check=True)


def prepare_app(app, work):
    copy = os.path.join(work, "app", "ShenzhenPDF Hover E2E.app")
    os.makedirs(os.path.dirname(copy))
    subprocess.run(["ditto", app, copy], check=True)
    info = os.path.join(copy, "Contents", "Info.plist")
    with open(info, "rb") as f:
        plist = plistlib.load(f)
    plist["CFBundleIdentifier"] = "com.intuition.shenzhenpdf.tab-hover-e2e"
    plist["LSUIElement"] = True
    with open(info, "wb") as f:
        plistlib.dump(plist, f)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", copy], check=True, capture_output=True)
    return copy


def run_phase(app, work, state, home, phase, documents, extras):
    out = os.path.join(work, phase, "out")
    os.makedirs(out)
    plan = os.path.join(work, phase, "plan.json")
    with open(plan, "w") as f:
        json.dump({"phase": phase, "documents": documents, "extras": extras, "group": GROUP}, f)
    env = {"PATH": "/usr/bin:/bin", "HOME": home, "CFFIXED_USER_HOME": home, "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "SPDF_STATE_DIR": state, "SPDF_NO_ACTIVATE": "1", "SZUT_ROOT": work,
           "SZUT_LOG": os.path.join(work, "szut.jsonl"), "SZUT_ROUTES": os.path.join(work, "routes.json"),
           "DYLD_INSERT_LIBRARIES": os.path.join(work, "szut.dylib") + ":" + os.path.join(work, "driver.dylib"),
           "SPDF_E2E_PLAN": plan, "SPDF_E2E_OUT": out}
    executable = os.path.join(app, "Contents", "MacOS", "ShenzhenPDF")
    with open(os.path.join(work, phase, "app.log"), "w") as log:
        process = subprocess.Popen([executable], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            process.wait(timeout=300)
        except subprocess.TimeoutExpired:
            print(f"FAIL the {phase} run did not finish within 5 minutes")
        finally:
            if process.poll() is None:
                os.kill(process.pid, signal.SIGKILL)
                process.wait()
    result = os.path.join(out, "result.json")
    return json.load(open(result)) if os.path.exists(result) else {}


def check(results, name, condition, detail=""):
    results.append({"check": name, "pass": bool(condition), "detail": detail})
    print(("PASS " if condition else "FAIL ") + name + (f" ({detail})" if detail else ""))


def turned_page_five(o):
    w, h = o.get("size", [0, 0])
    return w > h and o.get("right_edge") == "red" and o.get("left_edge") != "red" and o.get("top_left") == "dark"


A4_PORTRAIT = 595.0 / 842.0


def page_ok(kind, shot):
    """A thumbnail of the right page: the right shape and something drawn on it (never a blank box)."""
    page = shot.get("page", {})
    aspect, ink = page.get("aspect", 0), page.get("ink", 0)
    if not shot.get("card") or not shot.get("shown"):
        return False
    if kind in ("markdown", "text"):
        return abs(aspect - A4_PORTRAIT) < 0.02 and ink > 0.004
    if kind == "image":
        return abs(aspect - 400 / 250) < 0.03 and page.get("top_edge") == "red" and page.get("bottom_left") == "dark"
    return turned_page_five(page)


def summary(shot):
    return json.dumps({k: shot.get(k) for k in ("label", "card", "card_ms", "page")})


def gaps_ok(gaps):
    return gaps and all(g.get("shown_before") and not g.get("shown") for g in gaps if g.get("inside_strip"))


def verify(first, restored):
    c = []
    names = {"markdown": "Camera flex bring-up notes.md", "image": "Flex photo, top side.png",
             "text": "Sensor register dump.txt", "pdf": "Plates for rotation.pdf"}
    for look in ("light", "dark"):
        types = first.get(f"types_{look}", {})
        for kind in ("markdown", "image", "text", "pdf"):
            shot = types.get(kind, {})
            check(c, f"{look}: a {kind} tab shown since launch shows its name and its page", shot.get("label") == names[kind]
                  and page_ok(kind, shot) and shot.get("card_at_hover"), summary(shot))
        gaps = first.get(f"gaps_{look}", [])
        check(c, f"{look}: no label over any empty place in the tab bar ({len(gaps)} places)", gaps_ok(gaps),
              json.dumps([g for g in gaps if g.get("shown") or not g.get("shown_before")]))
        check(c, f"{look}: the place between a title tab and the +N badge is among them",
              any(g.get("gap") == "between a title tab and the +N badge" for g in gaps))
    part = first.get("partly_hidden", {})
    placement = part.get("placement", {})
    check(c, "a tab half under the +N badge: its label under the part that shows, none over the part that does not",
          part.get("label") == part.get("expected") and abs(placement.get("centre_offset", 99)) <= 1 and
          not part.get("hidden_part", {}).get("shown", True), json.dumps({k: part.get(k) for k in
          ("label", "expected", "placement", "tab_rect", "visible_rect", "hidden_part")}))
    changes = first.get("layout_changes", [])
    for change in changes:
        if "gaps" in change:
            check(c, "a narrower window: no label over any empty place", gaps_ok(change["gaps"]),
                  json.dumps([g for g in change["gaps"] if g.get("shown") or not g.get("shown_before")]))
            continue
        after, again = change.get("after", {}), change.get("rehover", {})
        check(c, f"{change.get('change')}: the label is the tab's under the pointer, or none, then the tab's again",
              not change.get("skipped") and change.get("before") and
              (not after.get("shown") or after.get("label") == after.get("under")) and
              again.get("label") == again.get("under") and bool(again.get("shown")) == bool(again.get("under")),
              json.dumps(change))
    cold_types = restored.get("cold_types", {})
    for kind in ("markdown", "image", "text"):
        shot = cold_types.get(kind, {})
        check(c, f"a {kind} tab never shown since launch: its page from the file", shot.get("label") == names[kind] and
              page_ok(kind, shot) and 0 <= shot.get("card_ms", -1) < 1500, summary(shot))
    for look in ("light", "dark"):
        doc, rot = first.get(f"document_{look}", {}), first.get(f"rotated_{look}", {})
        exp, col = first.get(f"group_expanded_{look}", {}), first.get(f"group_collapsed_{look}", {})
        long_name = "Interface specification for the camera flex and its connector, revision C.pdf"
        check(c, f"{look}: a document tab shows its full name, whole, and its page", doc.get("label") == long_name and
              doc.get("label_whole") and doc.get("card"), json.dumps({k: doc.get(k) for k in ("label", "label_whole", "card")}))
        check(c, f"{look}: the turned tab shows page 5 turned clockwise", rot.get("card") and
              turned_page_five(rot.get("orientation", {})), json.dumps(rot.get("orientation")))
        for name, shot in (("expanded", exp), ("collapsed", col)):
            check(c, f"{look}: the {name} group's title tab shows the group's full name, whole, no page",
                  shot.get("label") == GROUP and shot.get("label_whole") and not shot.get("card"),
                  json.dumps({k: shot.get(k) for k in ("label", "label_whole")}))
            p, q = shot.get("placement", {}), doc.get("placement", {})
            check(c, f"{look}: the {name} group label sits where a document's does",
                  p and q and abs(p["gap_below_item"] - q["gap_below_item"]) < 0.5 and abs(p["centre_offset"]) <= 1
                  and abs(q["centre_offset"]) <= 1 and shot.get("font") == doc.get("font"),
                  json.dumps({"group": p, "document": q}))
        check(c, f"{look}: the group name is longer than its title tab shows",
              exp.get("header_width", 999) < 200, str(exp.get("header_width")))
        check(c, f"{look}: hovering away onto empty tab bar hides the label",
              not first.get(f"away_empty_{look}", {}).get("shown", True))
        check(c, f"{look}: leaving the tab bar hides the label", not first.get(f"away_out_{look}", {}).get("shown", True))
    cached = first.get("cached_latency", {})
    check(c, "a cached thumbnail shows with the title within one frame (16.7 ms)",
          cached.get("card") and 0 <= cached.get("median_ms", 99) < 16.7, json.dumps(cached))
    mem = first.get("memory_30_tabs", {})
    check(c, "33 tabs: thumbnails stay within their 24 MB budget",
          first.get("tab_count") == 33 and mem.get("entries", 0) >= 32 and mem.get("bytes", 1 << 40) <= 24 << 20,
          json.dumps(mem))
    cold = restored.get("cold", {})
    # This is the first label of the session, hovered while the app is still launching: it builds the panel, as it
    # did before thumbnails. Measured 2026-10-26 over 5 launches each: median 7.5 ms (5.9..20.3), and 9.8 ms
    # (7.1..19.9) for the build before; launch work on other threads makes the spread. Two frames, not one.
    check(c, "a tab never shown since launch: the title shows at once, alone",
          cold.get("title_shown_at_hover") and not cold.get("card_at_hover") and 0 <= cold.get("title_ms", 99) < 33.4,
          json.dumps({k: cold.get(k) for k in ("title_shown_at_hover", "card_at_hover", "title_ms", "thumbnail_ms")}))
    check(c, "a tab never shown since launch: its page fades in from the file",
          restored.get("cold_after", {}).get("card") and 0 < cold.get("thumbnail_ms", -1) < 1000 and
          turned_page_five(restored.get("cold_orientation", {})), json.dumps(restored.get("cold_orientation")))
    check(c, "nothing is made at launch", restored.get("memory_at_launch", {}).get("entries", 1) == 0,
          json.dumps(restored.get("memory_at_launch")))
    warm = restored.get("memory_restored_warm", {})
    check(c, "after the idle start every restored tab has its thumbnail, within budget",
          warm.get("entries", 0) >= 29 and warm.get("bytes", 1 << 40) <= 24 << 20, json.dumps(warm))
    rc = restored.get("restored_cached_latency", {})
    check(c, "a thumbnail made in the background shows within one frame",
          rc.get("card") and 0 <= rc.get("median_ms", 99) < 16.7, json.dumps(rc))
    return c


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--compare-app", help="an earlier build: its memory and CPU on the same restored session")
    args = parser.parse_args()
    work = os.path.abspath(args.work)
    os.makedirs(work)
    home, state = os.path.join(work, "home"), os.path.join(work, "state")
    os.makedirs(home)
    os.makedirs(state)
    with open(os.path.join(state, "settings.yaml"), "w") as f:
        f.write(SETTINGS)
    with open(os.path.join(state, "ai-settings.yaml"), "w") as f:
        f.write("onboarding_revision: 2\nonboarding_step: 3\n")
    with open(os.path.join(work, "routes.json"), "w") as f:
        f.write("{}")
    # Not under a temporary folder: the reader asks for a Save As before turning a page of a PDF kept in one.
    documents_dir = os.path.join(os.path.expanduser("~/Library/Caches/shenzhen-build/tab-hover-e2e"),
                                 os.path.basename(work))
    documents = fixtures.make_documents(documents_dir)
    extras = fixtures.make_text_documents(documents_dir)
    app = prepare_app(args.app, work)
    build(SZUT, os.path.join(work, "szut.dylib"), "AppKit", "CoreServices", "Security")
    build(os.path.join(HERE, "driver.m"), os.path.join(work, "driver.dylib"), "AppKit", "QuartzCore")
    started = time.time()
    try:
        first = run_phase(app, work, state, home, "first", documents, extras)
        saved = os.path.join(work, "state-after-first")
        shutil.copytree(state, saved)
        restored = run_phase(app, work, state, home, "restored", documents, extras)
        memory = {}
        if args.compare_app:
            earlier = prepare_app(args.compare_app, os.path.join(work, "compare"))
            for name, which in (("memory-this", app), ("memory-earlier", earlier), ("memory-this-2", app),
                                ("memory-earlier-2", earlier)):
                copy = os.path.join(work, "state-" + name)
                shutil.copytree(saved, copy)
                memory[name] = run_phase(which, work, copy, home, name, documents, extras)
            print(json.dumps(memory, indent=1))
    finally:
        subprocess.run([sys.executable, NODIALOGS, "unregister", work])
        shutil.rmtree(documents_dir, ignore_errors=True)
    checks = verify(first, restored)
    with open(os.path.join(work, "checks.json"), "w") as f:
        json.dump({"seconds": round(time.time() - started), "checks": checks,
                   "first": first, "restored": restored, "memory": memory}, f, indent=1)
    failed = [x for x in checks if not x["pass"]]
    print(f"{len(checks) - len(failed)} of {len(checks)} checks passed; pictures in {work}/first/out, "
          f"{work}/restored/out")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
