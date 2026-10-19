// Builds friends-link.node, the main process's binding of the Shenzhen Friends client library
// (electron/friends/native/friends-link.c and friends-link-client.c), from the client library and cJSON of the
// shenzhen-pdf checkout that scripts/friends/setup-friends.sh verified against friends.lock. The library is compiled
// here rather than linked from that checkout's objects so the addon can target the app's architecture and minimum
// macOS.
//
//   node electron/friends/build-native.mjs [--arch=arm64|x64] [--output=<file>]   build
//   node electron/friends/build-native.mjs --check                               verify; print the addon's path
//
// The checkout is apps/pdf in the Shenzhen repository; elsewhere SZF_FRIENDS_ROOT names it, and without it,
// friends-src/ next to this repository's root (electron/friends/lock.cjs, friendsBuild).
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const require = createRequire(import.meta.url);
const { readFriendsLock, friendsBuild } = require("./lock.cjs");

// The client library's sources, as portable/friends/client/client.mk lists them.
export const CLIENT_SOURCES = [
  "szfriends_paths.c",
  "szfriends_framing.c",
  "szfriends_socket.c",
  "szfriends_signing.c",
  "szfriends_spawn.c",
  "szfriends_client.c",
  "szfriends_client_io.c",
  "szfriends_intents.c",
].map((name) => `portable/friends/client/${name}`);
const CJSON = "ext/cjson/cJSON.c";
// The binding: the module with its promise-returning calls, and the client object; the header they share.
const BINDING = [
  "electron/friends/native/friends-link.c",
  "electron/friends/native/friends-link-client.c",
];
const BINDING_HEADER = "electron/friends/native/friends-link.h";

export function friendsRoot() {
  return friendsBuild(root).root;
}
export function defaultOutput(arch = process.arch) {
  return path.join(root, "artifacts/friends-native", arch, "friends-link.node");
}
const sha256 = async (file) =>
  createHash("sha256")
    .update(await fs.readFile(file))
    .digest("hex");

// What the addon was built from: the pin and every source's digest. --check compares it with the sources now.
async function provenance(friends, arch) {
  const lock = readFriendsLock(root);
  const sources = {};
  for (const relative of [
    ...CLIENT_SOURCES,
    CJSON,
    "portable/friends/client/szfriends_client.h",
  ])
    sources[relative] = await sha256(path.join(friends, relative));
  for (const relative of [...BINDING, BINDING_HEADER])
    sources[relative] = await sha256(path.join(root, relative));
  return { commit: lock.commit, arch, sources };
}

async function nodeHeaders() {
  const candidates = [
    process.env.SHENZHEN_NODE_HEADERS,
    path.join(
      os.homedir(),
      "Library/Caches/node-gyp",
      process.versions.node,
      "include/node",
    ),
    path.resolve(path.dirname(process.execPath), "../include/node"),
    "/opt/homebrew/include/node",
    "/usr/local/include/node",
  ].filter(Boolean);
  for (const candidate of candidates) {
    try {
      // libuv's header too: the binding watches the client's descriptor on the main process's loop.
      await fs.access(path.join(candidate, "node_api.h"));
      await fs.access(path.join(candidate, "uv.h"));
      return candidate;
    } catch {}
  }
  throw Error(
    "Node N-API and libuv headers are required; set SHENZHEN_NODE_HEADERS to their include directory",
  );
}

export async function buildFriendsNative({
  output = defaultOutput(),
  arch = process.arch,
  friends = friendsRoot(),
} = {}) {
  if (process.platform !== "darwin") return undefined;
  if (!["arm64", "x64"].includes(arch))
    throw Error("Unsupported Friends addon architecture");
  const headers = await nodeHeaders();
  const target = [
    "-arch",
    arch === "x64" ? "x86_64" : "arm64",
    "-mmacosx-version-min=13.0",
  ];
  const objects = await fs.mkdtemp(path.join(os.tmpdir(), "friends-native-"));
  try {
    const compiled = [];
    // The library is C99 and libc only; cJSON exports nothing (hidden), as shenzhen-pdf's deps.mk builds it.
    for (const relative of [...CLIENT_SOURCES, CJSON]) {
      const object = path.join(objects, path.basename(relative, ".c") + ".o");
      execFileSync(
        "xcrun",
        [
          "clang",
          ...target,
          "-std=c99",
          "-O2",
          "-fvisibility=hidden",
          "-Wall",
          "-Wextra",
          "-I",
          path.join(friends, "portable/friends"),
          "-I",
          path.join(friends, "ext/cjson"),
          "-c",
          path.join(friends, relative),
          "-o",
          object,
        ],
        { stdio: "pipe" },
      );
      compiled.push(object);
    }
    const bindings = BINDING.map((relative) => {
      const object = path.join(
        objects,
        `binding-${path.basename(relative, ".c")}.o`,
      );
      execFileSync(
        "xcrun",
        [
          "clang",
          ...target,
          "-std=c11",
          "-O2",
          "-fvisibility=hidden",
          "-Wall",
          "-Wextra",
          "-DNODE_GYP_MODULE_NAME=friends_link",
          "-I",
          headers,
          "-I",
          path.join(friends, "portable/friends"),
          "-c",
          path.join(root, relative),
          "-o",
          object,
        ],
        { stdio: "pipe" },
      );
      return object;
    });
    await fs.mkdir(path.dirname(output), { recursive: true });
    execFileSync(
      "xcrun",
      [
        "clang",
        ...target,
        "-dynamiclib",
        "-Wl,-adhoc_codesign",
        "-undefined",
        "dynamic_lookup",
        ...bindings,
        ...compiled,
        "-framework",
        "Security",
        "-framework",
        "CoreFoundation",
        "-o",
        output,
      ],
      { stdio: "pipe" },
    );
  } finally {
    await fs.rm(objects, { recursive: true, force: true });
  }
  await fs.writeFile(
    output + ".json",
    JSON.stringify(await provenance(friends, arch), null, 2) + "\n",
  );
  return output;
}

// The addon exists and was built from exactly the pinned sources and this binding.
export async function checkFriendsNative({
  output = defaultOutput(),
  arch = process.arch,
  friends = friendsRoot(),
} = {}) {
  const recorded = JSON.parse(await fs.readFile(output + ".json", "utf8"));
  await fs.access(output);
  const now = await provenance(friends, arch);
  if (JSON.stringify(recorded) !== JSON.stringify(now))
    throw Error(`${output} was built from other sources; rebuild it`);
  return output;
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
) {
  const option = (name) =>
    process.argv
      .find((arg) => arg.startsWith(`--${name}=`))
      ?.slice(name.length + 3);
  const arch = option("arch") ?? process.arch;
  const output = option("output") ?? defaultOutput(arch);
  try {
    console.log(
      process.argv.includes("--check")
        ? await checkFriendsNative({ output, arch })
        : await buildFriendsNative({ output, arch }),
    );
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}
