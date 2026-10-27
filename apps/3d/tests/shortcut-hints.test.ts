// Shortcut hints (src/core/shortcuts.ts): Windows and Linux write Ctrl, a Mac and an iPad ⌘, and no component writes
// ⌘ itself. tests/e2e-shortcut-hints.spec.ts renders the whole app as Windows, Linux and Android and reads every hint.
import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import {
  ariaShortcut,
  detectKeyPlatform,
  modifierLabel,
  shortcutLabel,
} from "../src/core/shortcuts";

const windows = {
  platform: "Win32",
  userAgent:
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
  maxTouchPoints: 0,
};
const linux = {
  platform: "Linux x86_64",
  userAgent:
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
  maxTouchPoints: 0,
};

describe("shortcut hints", () => {
  it("tells the platforms apart", () => {
    expect(detectKeyPlatform(windows)).toBe("windows");
    expect(detectKeyPlatform(linux)).toBe("linux");
    expect(
      detectKeyPlatform({
        platform: "MacIntel",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
        maxTouchPoints: 0,
      }),
    ).toBe("mac");
    expect(
      detectKeyPlatform({
        platform: "MacIntel",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
        maxTouchPoints: 5,
      }),
    ).toBe("ios");
    expect(detectKeyPlatform({ platform: "iPhone", userAgent: "" })).toBe(
      "ios",
    );
    expect(
      detectKeyPlatform({
        platform: "Linux armv8l",
        userAgent: "Mozilla/5.0 (Linux; Android 15; 24117RK2CG) Mobile",
      }),
    ).toBe("android");
  });

  it("writes Ctrl on Windows, Linux and Android, ⌘ on a Mac and an iPad", () => {
    for (const platform of ["windows", "linux", "android"] as const) {
      expect(shortcutLabel("O", platform)).toBe("Ctrl+O");
      expect(shortcutLabel("J", platform)).toBe("Ctrl+J");
      expect(modifierLabel(platform)).toBe("Ctrl");
      expect(ariaShortcut("J", platform)).toBe("Control+J");
    }
    for (const platform of ["mac", "ios"] as const) {
      expect(shortcutLabel("O", platform)).toBe("⌘O");
      expect(modifierLabel(platform)).toBe("⌘");
      expect(ariaShortcut("J", platform)).toBe("Meta+J");
    }
  });

  it("leaves ⌘ to core/shortcuts.ts: no component, page or style writes it", () => {
    const root = path.resolve("src");
    const found: string[] = [];
    const walk = (directory: string) => {
      for (const name of readdirSync(directory)) {
        const file = path.join(directory, name);
        if (statSync(file).isDirectory()) walk(file);
        else if (
          /\.(tsx?|css|html)$/.test(name) &&
          file !== path.join(root, "core/shortcuts.ts")
        )
          readFileSync(file, "utf8")
            .split("\n")
            .forEach((line, index) => {
              // Comments may name the Mac's key; strings and markup may not.
              const code = line.replace(/\/\/.*$|^\s*(\/?\*|\{\/\*).*$/, "");
              if (code.includes("⌘"))
                found.push(`${path.relative(root, file)}:${index + 1}`);
            });
      }
    };
    walk(root);
    expect(found).toEqual([]);
  });
});
