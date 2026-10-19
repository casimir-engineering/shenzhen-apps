#!/usr/bin/env python3
"""Build only curated public website assets; no repository docs are auto-published."""
import argparse
import html
import json
import re
import shutil
from pathlib import Path
from urllib.parse import urlparse
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
REPO = "https://github.com/casimir-engineering/shenzhen-pdf"
DOWNLOAD = REPO + "/releases/latest/download/ShenzhenPDF-mac-arm64.dmg"


def build(base, output):
    base = base.rstrip("/") + "/"
    parsed = urlparse(base)
    if parsed.scheme != "https" or not parsed.netloc or parsed.query or parsed.fragment:
        raise ValueError("base must be an absolute HTTPS site URL")
    output.mkdir(parents=True, exist_ok=True)
    assets = output / "assets"
    assets.mkdir(exist_ok=True)
    shutil.copyfile(ROOT / "website/style.css", assets / "style.css")
    for name in ("macos-ai-chat.webp", "macos-markdown.webp", "macos-main-window.webp", "macos-groups.webp"):
        shutil.copyfile(ROOT / "website/assets" / name, assets / name)
    makefile = (ROOT / "portable/Makefile").read_text()
    version = re.search(r"^MAC_VERSION \?= (.+)$", makefile, re.M)[1]
    build_number = re.search(r"^MAC_BUILD \?= (.+)$", makefile, re.M)[1]
    for lang, path, other in (("en", "", "zh/"), ("zh-CN", "zh/", "")):
        content = json.loads((ROOT / "website" / ("en.json" if lang == "en" else "zh.json")).read_text())
        canonical = base + path
        schema = {
            "@context": "https://schema.org", "@type": "SoftwareApplication",
            "name": "Shenzhen PDF Reader", "alternateName": ["ShenzhenPDF", "深圳 PDF 阅读器"],
            "applicationCategory": "ProductivityApplication", "operatingSystem": "macOS 12 or later, Apple Silicon",
            "description": content["description"], "url": canonical,
            "downloadUrl": DOWNLOAD, "softwareVersion": f"{version}-{build_number}",
            "isAccessibleForFree": True, "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
            "screenshot": base + "assets/macos-ai-chat.webp", "sameAs": [REPO],
        }
        values = {**content, "lang": lang, "canonical": canonical, "base": base,
                  "alternate": base + other, "repo": REPO, "download": DOWNLOAD,
                  "version": f"{version}-{build_number}", "asset_prefix": "../" if path else ""}
        template = (ROOT / "website/page.html").read_text()
        for key, value in values.items():
            template = template.replace("{{" + key + "}}", html.escape(value, quote=True))
        template = template.replace("{{schema}}", json.dumps(schema, ensure_ascii=False).replace("<", "\\u003c"))
        if re.search(r"\{\{\w+\}\}", template):
            raise ValueError("Unresolved template field")
        target = output / path
        target.mkdir(parents=True, exist_ok=True)
        (target / "index.html").write_text(template)
    (output / ".nojekyll").touch()
    urls = (base, base + "zh/")
    (output / "sitemap.xml").write_text('<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' +
        "".join(f"  <url><loc>{escape(url)}</loc></url>\n" for url in urls) + '</urlset>\n')
    # robots.txt is authoritative only on a host root, not at a project subpath.
    # Keep the project sitemap linked in HTML and submit it through webmaster tools.
    if parsed.path == "/":
        (output / "robots.txt").write_text(f"User-agent: *\nAllow: /\nSitemap: {base}sitemap.xml\n")
    for file in (ROOT / "website/verification").glob("*"):
        if file.is_file():
            shutil.copyfile(file, output / file.name)
    print(f"Built {len(urls)} static pages at {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="https://casimir-engineering.github.io/shenzhen-pdf/")
    parser.add_argument("--output", type=Path, default=ROOT / "portable/build/website")
    args = parser.parse_args()
    build(args.base, args.output)
