#!/usr/bin/env python3
"""Check the generated public pages, metadata and crawlable local resources."""
import json
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse
from xml.etree import ElementTree as ET


class Page(HTMLParser):
    def __init__(self, source):
        super().__init__()
        self.tags = []
        self.schema = ""
        self.in_schema = False
        self.feed(source)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.tags.append((tag, attrs))
        if tag == "script":
            assert attrs.get("type") == "application/ld+json", "Pages must work without JavaScript"
            self.in_schema = True

    def handle_endtag(self, tag):
        if tag == "script":
            self.in_schema = False

    def handle_data(self, data):
        if self.in_schema:
            self.schema += data


def check(root):
    canonical_urls = []
    for relative, lang in (("index.html", "en"), ("zh/index.html", "zh-CN")):
        path = root / relative
        source = path.read_text()
        assert "{{" not in source
        page = Page(source)
        assert ("html", {"lang": lang}) in page.tags
        assert len([tag for tag, _ in page.tags if tag == "h1"]) == 1
        canonical = [a["href"] for t, a in page.tags if t == "link" and a.get("rel") == "canonical"]
        assert len(canonical) == 1 and canonical[0].startswith("https://")
        canonical_urls += canonical
        schema = json.loads(page.schema)
        assert schema["url"] == canonical[0] and schema["@type"] == "SoftwareApplication"
        assert "aggregateRating" not in schema, "Do not invent ratings"
        assert any(t == "meta" and a.get("name") == "description" and len(a["content"]) > 50 for t, a in page.tags)
        alternates = [a for t, a in page.tags if t == "link" and a.get("rel") == "alternate"]
        assert {a["hreflang"] for a in alternates} == {"en", "zh-CN", "x-default"}
        for tag, attrs in page.tags:
            if tag == "img":
                assert attrs.get("alt") and attrs.get("width") and attrs.get("height")
            for key in ("src", "href"):
                value = attrs.get(key, "")
                if value and not urlparse(value).scheme and not value.startswith("#"):
                    assert (path.parent / value).is_file(), value
    sitemap = ET.parse(root / "sitemap.xml")
    urls = [node.text for node in sitemap.findall(".//{http://www.sitemaps.org/schemas/sitemap/0.9}loc")]
    assert set(urls) == set(canonical_urls)
    assert not (root / "agent-handoff-private.md").exists()
    assert sum(p.stat().st_size for p in root.rglob("*") if p.is_file()) < 500_000
    print("Website checks passed: static bilingual content, metadata, sitemap, assets, size")


if __name__ == "__main__":
    check(Path(sys.argv[1] if len(sys.argv) > 1 else "portable/build/website"))
