#!/usr/bin/env node
// windows-installer-check.mjs — what Shenzhen 3D's Windows installers must carry for Friends to start, checked on the
// Mac from the files themselves, without Windows: the NSIS Setup and the MSI each hold the app and the Rust helper
// beside it (szfriends-helper.exe), the animal set and the helper's acknowledgements; the helper is a Windows GUI
// program for the app's architecture, carries this tree's helper build stamp, and needs no Visual C++ runtime DLL
// (it links the C runtime statically, so a fresh Windows runs it); both installers carry the same helper.
// scripts/friends/windows-installer-smoke.sh then runs the Setup in the Windows VM.
//
//   node scripts/friends/windows-installer-check.mjs --setup <Setup.exe> [--msi <file.msi>] [--arch x64|arm64]
//        [--helper-version 26.10.25 --helper-build 26102502]
//
// Without --helper-version and --helper-build the stamp expected is apps/pdf's (MAC_VERSION and MAC_BUILD in
// apps/pdf/portable/Makefile, as friends-lock.sh reads them in this tree). Needs 7-Zip (`7zz`, Homebrew's sevenzip).
import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const MACHINES = { x64: 0x8664, arm64: 0xaa64 };
const STAMP_MAGIC = Buffer.from("\0SZF-HELPER-STAMP-1\0", "latin1");
// The Visual C++ runtime DLLs a dynamically linked MSVC program imports; a fresh Windows does not have them.
const RUNTIME_DLLS = /^(vcruntime\d+(_\d+)?|msvcp\d+(_\w+)?|ucrtbased|vcruntime\d+d)\.dll$/i;

/** The helper build stamp apps/pdf's Makefile gives: version "YY.M.D" and build YYMMDDBB. */
export function treeStamp(root = path.resolve(here, "../../../pdf/portable")) {
  const makefile = fs.readFileSync(path.join(root, "Makefile"), "utf8");
  const read = (key) => makefile.match(new RegExp(`^${key} \\?= (\\S+)`, "m"))?.[1];
  const version = read("MAC_VERSION"),
    build = read("MAC_BUILD");
  if (!version || !build) throw Error(`no MAC_VERSION or MAC_BUILD in ${root}/Makefile`);
  const [y, m, d] = version.split(".").map(Number);
  const number = [y % 100, m, d, Number(build)].map((n) => String(n).padStart(2, "0")).join("");
  return { version: `${y % 100}.${m}.${d}`, build: Number(number) };
}

/** The stamp a helper binary carries (src/stamp.rs: magic, 24 bytes of version, 20 digits of build), or null. */
export function readStamp(bytes) {
  for (let at = bytes.indexOf(STAMP_MAGIC); at >= 0; at = bytes.indexOf(STAMP_MAGIC, at + 1)) {
    const field = bytes.subarray(at + 20, at + 44);
    const end = field.indexOf(0);
    const version = field.subarray(0, end < 0 ? 24 : end).toString("latin1");
    const digits = bytes.subarray(at + 44, at + 64).toString("latin1");
    if (/^\d+(\.\d+)+$/.test(version) && /^\d{20}$/.test(digits)) return { version, build: Number(digits) };
  }
  return null;
}

/** A PE file's machine, subsystem and imported DLL names. */
export function readPe(bytes) {
  if (bytes.readUInt16LE(0) !== 0x5a4d) throw Error("not a Windows program (no MZ header)");
  const pe = bytes.readUInt32LE(0x3c);
  if (bytes.readUInt32LE(pe) !== 0x4550) throw Error("not a Windows program (no PE header)");
  const machine = bytes.readUInt16LE(pe + 4);
  const sections = bytes.readUInt16LE(pe + 6);
  const optionalSize = bytes.readUInt16LE(pe + 20);
  const optional = pe + 24;
  const plus = bytes.readUInt16LE(optional) === 0x20b;
  const subsystem = bytes.readUInt16LE(optional + 68);
  const directories = optional + (plus ? 112 : 96);
  const importRva = bytes.readUInt32LE(directories + 8);
  const table = optional + optionalSize;
  const offsetOf = (rva) => {
    for (let i = 0; i < sections; i++) {
      const s = table + i * 40;
      const virtual = bytes.readUInt32LE(s + 12),
        size = Math.max(bytes.readUInt32LE(s + 8), bytes.readUInt32LE(s + 16));
      if (rva >= virtual && rva < virtual + size) return rva - virtual + bytes.readUInt32LE(s + 20);
    }
    throw Error(`RVA ${rva} is in no section`);
  };
  const imports = [];
  if (importRva) {
    for (let at = offsetOf(importRva); ; at += 20) {
      const nameRva = bytes.readUInt32LE(at + 12);
      if (!nameRva) break;
      const start = offsetOf(nameRva);
      imports.push(bytes.subarray(start, bytes.indexOf(0, start)).toString("latin1"));
    }
  }
  return { machine, subsystem, imports };
}

function sevenZip(args) {
  const run = spawnSync("7zz", args, { encoding: "utf8", maxBuffer: 64 << 20 });
  if (run.error?.code === "ENOENT") throw Error("7zz is missing: brew install sevenzip");
  if (run.status !== 0) throw Error(`7zz ${args.join(" ")} failed: ${run.stderr || run.stdout}`);
  return run.stdout;
}

/** The names an installer holds, as 7-Zip lists them. */
function names(installer) {
  return sevenZip(["l", "-slt", installer])
    .split("\n")
    .filter((line) => line.startsWith("Path = "))
    .map((line) => line.slice(7))
    .slice(1);
}

function extract(installer, name, into) {
  sevenZip(["e", "-y", `-o${into}`, installer, name]);
  return fs.readFileSync(path.join(into, path.basename(name.replaceAll("\\", "/"))));
}

/** Checks one installer; returns the helper's SHA-256. `kind` is "nsis" or "msi". */
export function checkInstaller(installer, kind, expected, log = console.log) {
  const listed = names(installer);
  const find = (pattern, what) => {
    const found = listed.filter((n) => pattern.test(n.replaceAll("\\", "/")));
    if (found.length !== 1) throw Error(`${path.basename(installer)}: ${found.length} entries for ${what}, not 1`);
    return found[0];
  };
  // The MSI names its files by their WiX ids (the helper's is Bin_szfriends_helper.exe); the app is the largest.
  const helperName = find(kind === "nsis" ? /^szfriends-helper\.exe$/ : /szfriends[-_]helper\.exe$/i, "the helper");
  if (kind === "nsis") {
    find(/^shenzhen-3d\.exe$/, "the app");
    find(/^friends\/animals\/manifest\.json$/, "the animal set");
    find(/^friends\/Acknowledgements\.txt$/, "the helper's acknowledgements");
  }
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "szf3d-wincheck-"));
  try {
    const helper = extract(installer, helperName, scratch);
    const pe = readPe(helper);
    if (pe.machine !== MACHINES[expected.arch])
      throw Error(`the helper is for machine 0x${pe.machine.toString(16)}, not ${expected.arch}`);
    if (pe.subsystem !== 2) throw Error(`the helper's subsystem is ${pe.subsystem}, not 2 (a GUI program, no console)`);
    const runtime = pe.imports.filter((dll) => RUNTIME_DLLS.test(dll));
    if (runtime.length)
      throw Error(`the helper needs ${runtime.join(", ")}, which a fresh Windows lacks: link the C runtime statically`);
    const stamp = readStamp(helper);
    if (!stamp) throw Error("the helper carries no build stamp");
    if (stamp.version !== expected.version || stamp.build !== expected.build)
      throw Error(`the helper is ${stamp.version} build ${stamp.build}, not ${expected.version} build ${expected.build}`);
    if (kind === "nsis") {
      const app = readPe(extract(installer, "shenzhen-3d.exe", scratch));
      if (app.machine !== pe.machine) throw Error("the app and its helper are for different machines");
    }
    log(
      `ok ${path.basename(installer)}: the helper ${stamp.version} build ${stamp.build} (${expected.arch}, ` +
        `GUI, imports ${pe.imports.length} system DLLs, no C runtime DLL) beside the app`,
    );
    return crypto.createHash("sha256").update(helper).digest("hex");
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

function main(argv) {
  const option = (name) => {
    const at = argv.indexOf(`--${name}`);
    return at >= 0 ? argv[at + 1] : undefined;
  };
  const setup = option("setup");
  if (!setup) throw Error("--setup <Setup.exe> is required");
  const tree = option("helper-version") && option("helper-build") ? null : treeStamp();
  const expected = {
    arch: option("arch") ?? "x64",
    version: option("helper-version") ?? tree.version,
    build: Number(option("helper-build") ?? tree.build),
  };
  if (!MACHINES[expected.arch]) throw Error(`--arch is x64 or arm64, not ${expected.arch}`);
  const digests = [checkInstaller(setup, "nsis", expected)];
  const msi = option("msi");
  if (msi) digests.push(checkInstaller(msi, "msi", expected));
  if (new Set(digests).size !== 1) throw Error("the Setup and the MSI carry different helpers");
  console.log("windows-installer-check: passed");
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(`windows-installer-check: ${error.message}`);
    process.exit(1);
  }
}
