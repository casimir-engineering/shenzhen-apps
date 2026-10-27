// node --test scripts/friends/windows-installer-check.test.mjs: the pieces of the Windows installer check that need
// no installer: the helper's stamp, a PE file's machine, subsystem and imports, and the stamp this tree expects.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { readPe, readStamp, treeStamp } from "./windows-installer-check.mjs";

/** A minimal PE32+ file: one section holding an import directory that names `dlls`. */
function pe({ machine = 0x8664, subsystem = 2, dlls = [] } = {}) {
  const bytes = Buffer.alloc(0x600);
  bytes.writeUInt16LE(0x5a4d, 0);
  bytes.writeUInt32LE(0x80, 0x3c);
  bytes.writeUInt32LE(0x4550, 0x80);
  bytes.writeUInt16LE(machine, 0x84);
  bytes.writeUInt16LE(1, 0x86); // one section
  bytes.writeUInt16LE(240, 0x94); // optional header size
  const optional = 0x98;
  bytes.writeUInt16LE(0x20b, optional);
  bytes.writeUInt16LE(subsystem, optional + 68);
  bytes.writeUInt32LE(0x1000, optional + 112 + 8); // import directory RVA
  const section = optional + 240;
  bytes.writeUInt32LE(0x400, section + 8); // virtual size
  bytes.writeUInt32LE(0x1000, section + 12); // virtual address
  bytes.writeUInt32LE(0x400, section + 16); // raw size
  bytes.writeUInt32LE(0x200, section + 20); // raw offset
  let name = 0x200 + 20 * (dlls.length + 1);
  dlls.forEach((dll, i) => {
    bytes.writeUInt32LE(0x1000 + (name - 0x200), 0x200 + i * 20 + 12);
    bytes.write(`${dll}\0`, name, "latin1");
    name += dll.length + 1;
  });
  return bytes;
}

test("a PE file's machine, subsystem and imported DLLs are read", () => {
  const read = readPe(pe({ dlls: ["kernel32.dll", "VCRUNTIME140.dll"] }));
  assert.equal(read.machine, 0x8664);
  assert.equal(read.subsystem, 2);
  assert.deepEqual(read.imports, ["kernel32.dll", "VCRUNTIME140.dll"]);
  assert.equal(readPe(pe({ machine: 0xaa64, subsystem: 3 })).subsystem, 3);
  assert.throws(() => readPe(Buffer.alloc(64)), /no MZ header/);
});

test("the helper's stamp is found wherever it is, and only in its exact form", () => {
  const stamp = (version, digits) =>
    Buffer.concat([
      Buffer.from("\0SZF-HELPER-STAMP-1\0", "latin1"),
      Buffer.concat([Buffer.from(version, "latin1"), Buffer.alloc(24 - version.length)]),
      Buffer.from(digits, "latin1"),
    ]);
  const binary = Buffer.concat([Buffer.alloc(1000, 7), stamp("26.10.27", "00000000000026102701"), Buffer.alloc(9)]);
  assert.deepEqual(readStamp(binary), { version: "26.10.27", build: 26102701 });
  assert.equal(readStamp(Buffer.alloc(100)), null);
  assert.equal(readStamp(stamp("26.x", "00000000000026102701")), null);
});

test("the expected stamp comes from apps/pdf's MAC_VERSION and MAC_BUILD", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "szf3d-stamp-"));
  fs.writeFileSync(path.join(root, "Makefile"), "X ?= 1\nMAC_VERSION ?= 2026.10.7\nMAC_BUILD ?= 3\n");
  assert.deepEqual(treeStamp(root), { version: "26.10.7", build: 26100703 });
  fs.rmSync(root, { recursive: true });
});
