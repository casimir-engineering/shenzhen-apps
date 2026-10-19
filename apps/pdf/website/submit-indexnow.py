#!/usr/bin/env python3
"""Notify Bing/IndexNow after deployment; receipt is not an indexing guarantee."""
import argparse
import json
import re
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.parse import urlparse
from xml.etree import ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument("--base", default="https://casimir-engineering.github.io/shenzhen-pdf/")
parser.add_argument("--key")
args = parser.parse_args()
if not args.key:
    keys = [p for p in (Path(__file__).parent / "verification").glob("*.txt")
            if re.fullmatch(r"[0-9a-f]{32}", p.stem)]
    assert len(keys) == 1, "Expected one public IndexNow ownership file"
    args.key = keys[0].read_text().strip()
base = args.base.rstrip("/") + "/"
assert urlparse(base).scheme == "https"
assert re.fullmatch(r"[0-9a-f]{32}", args.key)
key_location = base + args.key + ".txt"
with urlopen(key_location, timeout=30) as response:
    assert response.read().decode().strip() == args.key, "Published ownership file does not match"
with urlopen(base + "sitemap.xml", timeout=30) as response:
    sitemap = ET.fromstring(response.read())
urls = [node.text for node in sitemap.findall(".//{http://www.sitemaps.org/schemas/sitemap/0.9}loc")]
assert urls and all(url.startswith(base) for url in urls), "URLs must stay within this site's verified path"
payload = {"host": urlparse(base).netloc, "key": args.key, "keyLocation": key_location, "urlList": urls}
request = Request("https://www.bing.com/indexnow", data=json.dumps(payload).encode(),
                  headers={"Content-Type": "application/json; charset=utf-8"}, method="POST")
with urlopen(request, timeout=45) as response:
    print(f"IndexNow HTTP {response.status}: submitted {len(urls)} URLs. Indexing is not guaranteed.")
