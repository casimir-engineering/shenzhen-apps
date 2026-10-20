#!/usr/bin/env node
// A local copy of the GitHub releases of casimir-engineering/shenzhen-3D for the update tests: the releases list
// and the assets of one candidate release (a directory, as scripts/updates/release-updates.mjs leaves it), on
// 127.0.0.1 only. A test build of the app (feature updates-test-api) reads it when SHENZHEN_3D_UPDATES_API names it.
//
//   node scripts/updates/mock-github.mjs --dir <release dir> --tag preview-0.2.9 [--port 0] [--port-file <file>]
//     [--log <file>] [--tamper-once <asset name>] [--owner casimir-engineering]
//
// Besides the candidate, the list holds what the real one holds or could hold, which the app must pass over: a newer
// draft that carries a manifest, a newer Mac-only release (as preview-0.2.1 is), and preview-0.2.0, published before
// Windows, Linux and iOS could update. Downloads answer as GitHub's do: a 302 to another address, then the bytes.
// --tamper-once changes one byte of that asset the first time it is downloaded. Every request is logged.
import { createServer } from "node:http";
import {
  appendFileSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";

const option = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`);
  if (index < 0) return fallback;
  return process.argv[index + 1];
};
const dir = option("dir");
const tag = option("tag");
if (!dir || !tag) {
  console.error(
    "usage: mock-github.mjs --dir <release dir> --tag <tag> [--port N] [--port-file F] [--log F]",
  );
  process.exit(2);
}
const owner = option("owner", "casimir-engineering");
const tamperOnce = option("tamper-once");
const logFile = option("log");
const log = (line) => {
  const text = `${new Date().toISOString()} ${line}`;
  console.log(text);
  if (logFile) appendFileSync(logFile, `${text}\n`);
};
const files = readdirSync(dir).filter(
  (name) => !name.endsWith(".sig") && statSync(path.join(dir, name)).isFile(),
);
let tampered = false;
let base = "";

const asset = (releaseTag, name, size) => ({
  name,
  size,
  browser_download_url: `${base}/download/${releaseTag}/${encodeURIComponent(name)}`,
  content_type: "application/octet-stream",
  state: "uploaded",
});
const release = (releaseTag, assets, { draft = false } = {}) => ({
  tag_name: releaseTag,
  name: `Shenzhen 3D ${releaseTag.replace(/^preview-/, "")}`,
  draft,
  prerelease: true,
  html_url: `https://github.com/${owner}/shenzhen-3D/releases/tag/${releaseTag}`,
  assets,
});
const version = tag.replace(/^(preview-|v)/, "");
const [major, minor, patch] = version.split(".").map(Number);
const newerMinor = `${major}.${minor + 1}.0`;
const newerPatch = `${major}.${minor}.${patch + 1}`;
function releases() {
  const candidate = files.map((name) =>
    asset(tag, name, statSync(path.join(dir, name)).size),
  );
  return [
    release(
      `preview-${newerMinor}`,
      [
        asset(`preview-${newerMinor}`, "latest.json", 900),
        asset(`preview-${newerMinor}`, "SHA256SUMS.txt", 100),
        asset(`preview-${newerMinor}`, "manifest.plist", 900),
      ],
      { draft: true },
    ),
    release(`preview-${newerPatch}`, [
      asset(
        `preview-${newerPatch}`,
        `Shenzhen-3D-${newerPatch}-Apple-Silicon.zip`,
        142_000_000,
      ),
      asset(`preview-${newerPatch}`, "latest-mac.yml", 500),
    ]),
    release(tag, candidate),
    release("preview-0.2.1", [
      asset(
        "preview-0.2.1",
        "Shenzhen-3D-0.2.1-Apple-Silicon.zip",
        142_000_000,
      ),
      asset("preview-0.2.1", "latest-mac.yml", 500),
    ]),
    release(
      "preview-0.2.0",
      [
        "Shenzhen-3D-0.2.0-Windows-x64-Setup.exe",
        "Shenzhen-3D-0.2.0-Windows-x64.msi",
        "Shenzhen-3D-0.2.0-Linux-arm64.AppImage",
        "Shenzhen-3D-0.2.0-Linux-arm64.deb",
        "shenzhen-3d-0.2.0-ios-registered-devices.ipa",
        "SHA256SUMS.txt",
      ].map((name) => asset("preview-0.2.0", name, 1000)),
    ),
  ];
}

function body(name) {
  let bytes = readFileSync(path.join(dir, name));
  if (name === "latest.json" || name === "manifest.plist") {
    // The candidate's files name GitHub; here they are served from this copy.
    const github = `https://github.com/${owner}/shenzhen-3D/releases/download/`;
    bytes = Buffer.from(
      bytes.toString("utf8").split(github).join(`${base}/download/`),
    );
  }
  if (name === tamperOnce && !tampered) {
    tampered = true;
    bytes = Buffer.from(bytes);
    bytes[Math.floor(bytes.length / 2)] ^= 0xff;
    log(`tampered one byte of ${name}`);
  }
  return bytes;
}

const server = createServer((request, response) => {
  const url = new URL(request.url, base);
  const send = (status, data, type = "application/json", extra = {}) => {
    log(`${request.method} ${url.pathname}${url.search} ${status}`);
    response.writeHead(status, {
      "content-type": type,
      "content-length": data.length,
      ...extra,
    });
    response.end(request.method === "HEAD" ? undefined : data);
  };
  if (url.pathname === `/repos/${owner}/shenzhen-3D/releases`) {
    return send(200, Buffer.from(JSON.stringify(releases(), null, 2)));
  }
  let match = url.pathname.match(/^\/download\/([^/]+)\/([^/]+)$/);
  if (match) {
    // As GitHub does: the asset address answers with a redirect to where the bytes are.
    return send(302, Buffer.alloc(0), "text/html", {
      location: `${base}/objects/${match[1]}/${match[2]}?token=1`,
    });
  }
  match = url.pathname.match(/^\/objects\/([^/]+)\/([^/]+)$/);
  if (match) {
    const name = decodeURIComponent(match[2]);
    if (match[1] !== tag || !files.includes(name))
      return send(404, Buffer.from("Not Found"), "text/plain");
    return send(200, body(name), "application/octet-stream", {
      "content-disposition": `attachment; filename=${name}`,
    });
  }
  send(404, Buffer.from('{"message":"Not Found"}'));
});
server.listen(Number(option("port", "0")), "127.0.0.1", () => {
  base = `http://127.0.0.1:${server.address().port}`;
  log(`serving ${tag} from ${dir} at ${base} (${files.length} files)`);
  const portFile = option("port-file");
  if (portFile) writeFileSync(portFile, String(server.address().port));
});
