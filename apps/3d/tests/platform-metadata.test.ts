import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
const read = (file: string) =>
  readFileSync(new URL("../" + file, import.meta.url), "utf8");
const pkg = JSON.parse(read("package.json"));
const tauri = JSON.parse(read("src-tauri/tauri.conf.json"));

describe("native platform metadata", () => {
  it("uses one neutral application ID across generated platform entry points", () => {
    expect(tauri.identifier).toBe("com.shenzhen3d.viewer");
    const gradle = read("src-tauri/gen/android/app/build.gradle.kts");
    expect(gradle.match(/namespace = "([^"]+)"/)?.[1]).toBe(tauri.identifier);
    expect(gradle.match(/applicationId = "([^"]+)"/)?.[1]).toBe(
      tauri.identifier,
    );
    expect(
      read(
        `src-tauri/gen/android/app/src/main/java/${tauri.identifier.replaceAll(".", "/")}/MainActivity.kt`,
      ),
    ).toMatch(
      new RegExp(`^package ${tauri.identifier.replaceAll(".", "\\.")}`),
    );
    const apple = read("src-tauri/gen/apple/project.yml");
    expect(apple.match(/PRODUCT_BUNDLE_IDENTIFIER: (\S+)/)?.[1]).toBe(
      tauri.identifier,
    );
    const identifiers = [
      ...read(
        "src-tauri/gen/apple/shenzhen-3d.xcodeproj/project.pbxproj",
      ).matchAll(/PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);/g),
    ];
    expect(identifiers).toHaveLength(2);
    expect(identifiers.every((match) => match[1] === tauri.identifier)).toBe(
      true,
    );
  });
  it("takes the version people see from package.json alone", () => {
    // Tauri reads the version from package.json, so Windows, Linux, Android and iOS cannot drift from it; Android
    // sets only its versionCode, and the Rust side gets package.json's version from build.rs.
    expect(tauri.version).toBe("../package.json");
    const android = JSON.parse(read("src-tauri/tauri.android.conf.json"));
    expect(android.version).toBeUndefined();
    expect(Number.isInteger(android.bundle.android.versionCode)).toBe(true);
    for (const file of ["src/lib.rs", "src/friends.rs", "src/app_updates.rs"])
      expect(read(`src-tauri/${file}`)).not.toContain("CARGO_PKG_VERSION");
    // The footer shows the version the app runs as when it can tell (the one Updates compares).
    const app = read("src/App.tsx");
    expect(app).toContain("v${runningVersion ?? builtVersion} · Updates");
    expect(app).not.toContain("package.json");
  });
  it("keeps mobile version and build numbers aligned with the product", () => {
    const lock = JSON.parse(read("package-lock.json"));
    expect(lock.version).toBe(pkg.version);
    expect(lock.packages[""].version).toBe(pkg.version);
    const apple = read("src-tauri/gen/apple/project.yml");
    expect(apple.match(/CFBundleShortVersionString: (\S+)/)?.[1]).toBe(
      pkg.version,
    );
    expect(apple.match(/CFBundleVersion: "([^"]+)"/)?.[1]).toBe(pkg.version);
    const plist = read("src-tauri/gen/apple/shenzhen-3d_iOS/Info.plist");
    for (const key of ["CFBundleShortVersionString", "CFBundleVersion"])
      expect(
        plist.match(
          new RegExp(`<key>${key}</key>\\s*<string>([^<]+)</string>`),
        )?.[1],
      ).toBe(pkg.version);
    expect(
      read("src-tauri/Cargo.toml").match(/^version = "([^"]+)"/m)?.[1],
    ).toBe(pkg.version);
    expect(
      read("src-tauri/Cargo.lock").match(
        /name = "shenzhen-3d"\nversion = "([^"]+)"/,
      )?.[1],
    ).toBe(pkg.version);
  });
});
