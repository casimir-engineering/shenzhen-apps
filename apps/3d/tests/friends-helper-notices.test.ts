// The acknowledgements Windows and Linux packages carry beside the Rust helper (scripts/friends/helper-notices.mjs).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
// @ts-expect-error: a plain JavaScript module of the build scripts
import {
  helperNotices,
  linksLibdbus,
} from "../scripts/friends/helper-notices.mjs";

const entry = (name: string, body = "Some licence text.") =>
  `${name}\nhttps://example.org\nA licence\n\n${body}`;
const acknowledgements = [
  "Shenzhen Friends: acknowledgements\n\nShenzhen Friends includes the following third-party software and data.",
  entry("libsodium 1.0.22"),
  entry("cJSON 1.7.19"),
  entry("EFF Large Wordlist for Passphrases"),
  entry("libdatachannel 0.24.6 and libjuice 1.7.4"),
  entry("usrsctp"),
  entry("plog"),
  entry("Mbed TLS 3.6.7"),
  entry("miniupnpc 2.3.3"),
].join("\n\n\n");
const lockfile = '[[package]]\nname = "libdbus-sys"\nversion = "0.2.7"\n';
const licenses = path.join(__dirname, "../src-tauri/friends/licenses");
const copying = ["libdbus-COPYING-1.txt", "libdbus-COPYING-2.txt"]
  .map((name) => fs.readFileSync(path.join(licenses, name), "utf8"))
  .join("");

describe("the Rust helper's acknowledgements", () => {
  it("keep what the helper carries and leave out what only the Mac helper does", () => {
    const text = helperNotices({
      acknowledgements,
      libdbusCopying: null,
      lockfile,
    });
    for (const name of [
      "EFF Large Wordlist",
      "libdatachannel",
      "usrsctp",
      "plog",
      "Mbed TLS",
      "SQLite",
    ])
      expect(text).toContain(`\n${name}`);
    for (const name of ["libsodium", "cJSON", "miniupnpc", "libdbus"])
      expect(text).not.toContain(name);
  });

  it("name libdbus with both its licences when the helper links it", () => {
    const text = helperNotices({
      acknowledgements,
      libdbusCopying: copying,
      lockfile,
    });
    expect(text).toMatch(/\nlibdbus 1\.14\.4\n/);
    expect(text).toContain("AFL-2.1 OR GPL-2.0-or-later");
    expect(text).toContain("The Academic Free License\nv. 2.1");
    expect(text).toContain(
      "GNU GENERAL PUBLIC LICENSE\n\t\t       Version 2, June 1991",
    );
  });

  it("refuse a libdbus-sys other than the one the texts came from", () => {
    const other = lockfile.replace("0.2.7", "0.2.8");
    expect(() =>
      helperNotices({
        acknowledgements,
        libdbusCopying: copying,
        lockfile: other,
      }),
    ).toThrow(/0\.2\.8/);
  });

  it("refuse acknowledgements missing an entry the helper carries", () => {
    const without = acknowledgements.replace(
      "\n\n\nplog\n",
      "\n\n\nsomething else\n",
    );
    expect(() =>
      helperNotices({
        acknowledgements: without,
        libdbusCopying: null,
        lockfile,
      }),
    ).toThrow(/plog/);
  });

  it("tell from the helper itself whether libdbus is in", () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "szf3d-notices-"));
    try {
      const helper = path.join(directory, "szfriends-helper");
      fs.writeFileSync(
        helper,
        Buffer.from("\0\x7fELF org.freedesktop.DBus.Error.NoMemory\0"),
      );
      expect(linksLibdbus(helper)).toBe(true);
      fs.writeFileSync(helper, Buffer.from("\0\x7fELF org.bluez\0"));
      expect(linksLibdbus(helper)).toBe(false);
    } finally {
      fs.rmSync(directory, { recursive: true, force: true });
    }
  });
});
