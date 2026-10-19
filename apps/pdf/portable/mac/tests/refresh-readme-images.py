#!/usr/bin/env python3
"""Encode complete native fixture windows for the README and website.

Run mac-workspace-probe and mac-ai-readme-probe into the same evidence directory:
python3 portable/mac/tests/refresh-readme-images.py /tmp/sz-readme-evidence
Requires cwebp. No screen capture, user documents, or window cropping.
"""
import shutil
import subprocess
import sys
from pathlib import Path

source = Path(sys.argv[1])
root = Path(__file__).resolve().parents[3]
destination = root / "docs/images/portable"
website = root / "website/assets"
website.mkdir(exist_ok=True)


def encode(source_file, output, width=None):
    args = ["cwebp", "-quiet", "-q", "85" if width else "90", "-m", "6"]
    if width:
        args += ["-resize", str(width), "0"]
    subprocess.run(args + [str(source_file), "-o", str(output)], check=True)


for fixture, name in (("reader-dark-find.png", "macos-search-highlights.webp"),
                      ("reader-dark-1280.png", "macos-groups.webp"),
                      ("reader-light-markdown-1280.png", "macos-markdown.webp")):
    encode(source / fixture, destination / name)
    site_name = "macos-main-window.webp" if "search" in name else name
    encode(source / fixture, website / site_name, 1280)
shutil.copyfile(source / "macos-ai-chat.png", destination / "macos-ai-chat.png")
encode(source / "macos-ai-chat.png", website / "macos-ai-chat.webp", 1600)
print("Wrote four full-window README images and four optimized website images.")
