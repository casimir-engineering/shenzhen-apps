#!/usr/bin/env node
// helper-notices.mjs — the acknowledgements Windows and Linux packages carry beside the Rust helper
// (src-tauri/friends/Acknowledgements.txt, which src-tauri/friends/tauri.conf.json bundles): the third-party code and
// data built into the helper, each with its licence. They are taken from the pinned shenzhen-pdf's
// portable/friends/ACKNOWLEDGEMENTS.txt, which lists what the Mac helper carries, keeping only the entries the Rust
// helper carries too, and adding SQLite and, when the helper was built with Bluetooth (Linux, through BlueZ), libdbus,
// which it links statically from the sources libdbus-sys carries. Whether libdbus is in is read from the built helper
// itself, so the notice follows the build rather than a guess about it.
//
//   node scripts/friends/helper-notices.mjs <helper> <portable/friends> <out>
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Entries of ACKNOWLEDGEMENTS.txt (each begins with its name) that the Rust helper carries: the Friends ID words and
// the online stack. libsodium, cJSON and miniupnpc are the Objective-C helper's only.
const CARRIED = [
  "EFF Large Wordlist for Passphrases",
  "libdatachannel",
  "usrsctp",
  "plog",
  "Mbed TLS",
];

// The libdbus that libdbus-sys builds from its own copy of the sources; the texts beside this file are its COPYING.
const LIBDBUS_SYS = "0.2.7";
const LIBDBUS = "1.14.4";
// A string libdbus itself carries (DBUS_ERROR_NO_MEMORY): the helper holds it only when libdbus is linked.
const LIBDBUS_MARK = "org.freedesktop.DBus.Error.NoMemory";

const SQLITE = `SQLite
https://sqlite.org
Public domain

The authors of SQLite have dedicated it to the public domain (https://sqlite.org/copyright.html).`;

const libdbusEntry = (copying) => `libdbus ${LIBDBUS}
https://www.freedesktop.org/wiki/Software/dbus/
Academic Free License 2.1 or GNU General Public License 2.0 or later (AFL-2.1 OR GPL-2.0-or-later); Shenzhen
Friends uses it under the Academic Free License 2.1

Copyright (C) 2002-2022 Red Hat, Inc., Collabora Ltd. and the other contributors named in the source files.

Used without changes, as the libdbus-sys ${LIBDBUS_SYS} crate carries it (vendor/dbus); the same sources are at
https://gitlab.freedesktop.org/dbus/dbus (tag dbus-${LIBDBUS}). Linked statically into the helper, which uses it
to reach the system's Bluetooth service.

${copying.trim()}`;

/** Whether the helper binary at `helper` has libdbus linked in. */
export function linksLibdbus(helper) {
  return fs.readFileSync(helper).includes(Buffer.from(LIBDBUS_MARK));
}

/**
 * The notice's text. `acknowledgements` is ACKNOWLEDGEMENTS.txt's text, `libdbusCopying` libdbus' COPYING when the
 * helper links libdbus (else null), `lockfile` the core's Cargo.lock (to check libdbus-sys is the one the COPYING
 * here came from).
 */
export function helperNotices({ acknowledgements, libdbusCopying, lockfile }) {
  const entries = acknowledgements.replaceAll("\r\n", "\n").split("\n\n\n");
  const header = entries.shift();
  const kept = CARRIED.map((name) => {
    const entry = entries.find((text) => text.startsWith(name));
    if (!entry) throw Error(`ACKNOWLEDGEMENTS.txt has no entry for ${name}`);
    return entry.trim();
  });
  kept.push(SQLITE);
  if (libdbusCopying !== null) {
    const pinned = lockfile.match(
      /name = "libdbus-sys"\nversion = "([^"]+)"/,
    )?.[1];
    if (pinned !== LIBDBUS_SYS)
      throw Error(
        `the core locks libdbus-sys ${pinned}, but the libdbus notice is for ${LIBDBUS_SYS} (libdbus ${LIBDBUS}): ` +
          "update it and the COPYING texts in src-tauri/friends/licenses",
      );
    kept.push(libdbusEntry(libdbusCopying));
  }
  return `${header.trim()}\n\n\n${kept.join("\n\n\n")}\n`;
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  const [helper, friends, out] = process.argv.slice(2);
  if (!helper || !friends || !out) {
    console.error(
      "usage: helper-notices.mjs <helper> <portable/friends> <out>",
    );
    process.exit(64);
  }
  const licenses = fileURLToPath(
    new URL("../../src-tauri/friends/licenses", import.meta.url),
  );
  const libdbus = linksLibdbus(helper);
  const text = helperNotices({
    acknowledgements: fs.readFileSync(
      path.join(friends, "ACKNOWLEDGEMENTS.txt"),
      "utf8",
    ),
    libdbusCopying: libdbus
      ? ["libdbus-COPYING-1.txt", "libdbus-COPYING-2.txt"]
          .map((name) => fs.readFileSync(path.join(licenses, name), "utf8"))
          .join("")
      : null,
    lockfile: fs.readFileSync(
      path.join(friends, "core-rs", "Cargo.lock"),
      "utf8",
    ),
  });
  fs.writeFileSync(out, text);
  console.log(`wrote ${out}${libdbus ? " (with libdbus)" : ""}`);
}
