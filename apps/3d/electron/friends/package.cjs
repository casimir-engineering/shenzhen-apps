// Shenzhen Friends in the packaged Mac app, as ShenzhenPDF and Shenzhen Files embed it:
//   Contents/Helpers/Shenzhen Friends.app           the helper built from the pin, signed on its own before the app
//   Contents/Resources/Friends/animals/             the animal set (manifest.json, svg/, pdf/)
//   Contents/Resources/Friends/Acknowledgements.txt the third-party notices Friends ships with
//   app.asar.unpacked/electron/native/friends-link.node   the client addon (staged with the runtime, package-mac.mjs)
// and the helper's usage descriptions and Bonjour type in the app's Info.plist, because macOS holds the app
// responsible for the helper it starts.
//
// stageFriends() copies the pieces into the packaging staging directory; embedFriends() runs from electron-builder's
// afterPack, before the app is signed; checkFriendsBundle() verifies a built app.
const fs = require("node:fs/promises");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const {
  HELPER_NAME,
  HELPER_ID,
  readFriendsLock,
  friendsBuild,
} = require("./lock.cjs");

const STAGED = "friends";
const USAGE_KEYS = [
  "NSLocalNetworkUsageDescription",
  "NSBluetoothAlwaysUsageDescription",
  "NSBonjourServices",
];

const plistJSON = (file) =>
  JSON.parse(
    execFileSync("plutil", ["-convert", "json", "-o", "-", file], {
      encoding: "utf8",
    }),
  );

/** Copies the pinned helper, animal set and notices into <staging>/friends/. */
async function stageFriends(staging, { repoRoot, env = process.env } = {}) {
  const build = friendsBuild(repoRoot, env);
  const lock = readFriendsLock(repoRoot);
  const target = path.join(staging, STAGED);
  await fs.rm(target, { recursive: true, force: true });
  await fs.mkdir(path.join(target, "Friends/animals/svg"), { recursive: true });
  await fs.mkdir(path.join(target, "Friends/animals/pdf"), { recursive: true });
  const helper = path.join(target, `${HELPER_NAME}.app`);
  execFileSync("ditto", [build.helperApp, helper]);
  // In an app the helper reads the set from the app's Resources/Friends (SZFriendsAnimalSet), not its own copy.
  await fs.rm(path.join(helper, "Contents/Resources/Friends"), {
    recursive: true,
    force: true,
  });
  await fs.copyFile(
    path.join(build.animals, "manifest.json"),
    path.join(target, "Friends/animals/manifest.json"),
  );
  for (const kind of ["svg", "pdf"])
    for (const name of await fs.readdir(path.join(build.animals, kind)))
      if (name.endsWith(`.${kind}`))
        await fs.copyFile(
          path.join(build.animals, kind, name),
          path.join(target, "Friends/animals", kind, name),
        );
  await fs.copyFile(
    build.acknowledgements,
    path.join(target, "Friends/Acknowledgements.txt"),
  );
  const info = plistJSON(path.join(helper, "Contents/Info.plist"));
  if (
    info.CFBundleIdentifier !== HELPER_ID ||
    Number(info.SZFriendsBuildNumber) !== lock.buildNumber
  )
    throw Error(
      `The staged Friends helper does not match ${lock.keysFrom} ` +
        `(${info.CFBundleIdentifier} ${info.SZFriendsBuildNumber}); run scripts/friends/setup-friends.sh`,
    );
  return {
    commit: lock.commit,
    helperBuildNumber: lock.buildNumber,
    helperVersion: info.CFBundleShortVersionString,
  };
}

/** electron-builder afterPack: puts the staged pieces into the app and signs the helper on its own. */
async function embedFriends(appPath, projectDir, { identity } = {}) {
  const staged = path.join(projectDir, STAGED);
  try {
    await fs.access(path.join(staged, `${HELPER_NAME}.app`));
  } catch {
    return false; // Packaged without Friends (a fixture build); the app then offers none of it.
  }
  const helpers = path.join(appPath, "Contents/Helpers");
  await fs.mkdir(helpers, { recursive: true });
  execFileSync("ditto", [
    path.join(staged, `${HELPER_NAME}.app`),
    path.join(helpers, `${HELPER_NAME}.app`),
  ]);
  execFileSync("ditto", [
    path.join(staged, "Friends"),
    path.join(appPath, "Contents/Resources/Friends"),
  ]);
  const appPlist = path.join(appPath, "Contents/Info.plist");
  const helperInfo = plistJSON(
    path.join(helpers, `${HELPER_NAME}.app/Contents/Info.plist`),
  );
  // plutil takes each value as one argument; PlistBuddy would parse quotes inside the helper's sentences.
  for (const key of USAGE_KEYS)
    execFileSync("plutil", [
      "-replace",
      key,
      "-json",
      JSON.stringify(helperInfo[key]),
      appPlist,
    ]);
  // The helper is signed here, before electron-builder signs the app around it (mac.signIgnore keeps it from
  // re-signing the helper with the app's entitlements). Tests and local builds sign ad hoc; a release identity adds
  // the hardened runtime and a timestamp, as ShenzhenPDF signs its helper.
  const helper = path.join(helpers, `${HELPER_NAME}.app`);
  const adHoc = !identity || identity === "-";
  // codesign needs a name only one certificate matches. electron-builder looks the configured name up among
  // Developer ID Application certificates, so a name without its type is taken as that one here too: the same
  // team's Apple Distribution certificate in the keychain would otherwise make it ambiguous.
  const signer =
    adHoc || /^[^:]+: /.test(identity)
      ? identity
      : `Developer ID Application: ${identity}`;
  execFileSync(
    "codesign",
    adHoc
      ? ["--force", "--sign", "-", helper]
      : [
          "--force",
          "--options",
          "runtime",
          "--timestamp",
          "--sign",
          signer,
          helper,
        ],
    { stdio: "pipe" },
  );
  return true;
}

/** Every problem with the Friends pieces of a built app; an empty list when they are as the pin says. */
async function friendsBundleProblems(appPath, repoRoot) {
  const lock = readFriendsLock(repoRoot);
  const problems = [];
  const helper = path.join(appPath, "Contents/Helpers", `${HELPER_NAME}.app`);
  const exists = async (file) =>
    fs.access(file).then(
      () => true,
      () => false,
    );
  if (!(await exists(path.join(helper, "Contents/MacOS", HELPER_NAME))))
    return [`no helper at ${helper}`];
  const info = plistJSON(path.join(helper, "Contents/Info.plist"));
  const expect = {
    CFBundleIdentifier: HELPER_ID,
    CFBundleShortVersionString: lock.shortVersion,
    CFBundleVersion: String(lock.buildNumber),
    SZFriendsBuildNumber: String(lock.buildNumber),
  };
  for (const [key, want] of Object.entries(expect))
    if (String(info[key]) !== want)
      problems.push(
        `the helper's ${key} is ${info[key]}, ${lock.keysFrom} asks for ${want}`,
      );
  if (await exists(path.join(helper, "Contents/Resources/Friends")))
    problems.push("the helper still carries its own animal set");
  for (const file of [
    "Friends/animals/manifest.json",
    "Friends/Acknowledgements.txt",
  ])
    if (!(await exists(path.join(appPath, "Contents/Resources", file))))
      problems.push(`Resources/${file} is missing`);
  const manifest = JSON.parse(
    await fs
      .readFile(
        path.join(appPath, "Contents/Resources/Friends/animals/manifest.json"),
        "utf8",
      )
      .catch(() => "{}"),
  );
  for (const animal of manifest.animals ?? [])
    if (
      !(await exists(
        path.join(appPath, "Contents/Resources/Friends/animals", animal.svg),
      ))
    )
      problems.push(`the animal set lacks ${animal.svg}`);
  const app = plistJSON(path.join(appPath, "Contents/Info.plist"));
  for (const key of USAGE_KEYS)
    if (JSON.stringify(app[key]) !== JSON.stringify(info[key]))
      problems.push(`the app's ${key} differs from the helper's`);
  if (
    !(await exists(
      path.join(
        appPath,
        "Contents/Resources/app.asar.unpacked/electron/native/friends-link.node",
      ),
    ))
  )
    problems.push("the client addon is not unpacked beside app.asar");
  try {
    execFileSync("codesign", ["--verify", "--strict", helper], {
      stdio: "pipe",
    });
  } catch (error) {
    problems.push(
      `the helper's signature does not verify: ${String(error.stderr || error.message).trim()}`,
    );
  }
  // Static libsodium and system frameworks only: nothing outside /usr/lib and /System.
  const libraries = execFileSync(
    "otool",
    ["-L", path.join(helper, "Contents/MacOS", HELPER_NAME)],
    { encoding: "utf8" },
  )
    .split("\n")
    .slice(1)
    .map((line) => line.trim().split(" ")[0])
    .filter(Boolean);
  for (const library of libraries)
    if (!library.startsWith("/usr/lib/") && !library.startsWith("/System/"))
      problems.push(`the helper links ${library}`);
  return problems;
}

async function checkFriendsBundle(appPath, repoRoot) {
  const problems = await friendsBundleProblems(appPath, repoRoot);
  const source =
    readFriendsLock(repoRoot).mode === "tree"
      ? "apps/pdf as it is now"
      : "friends.lock";
  if (problems.length)
    throw Error(
      `The app's Friends pieces do not match ${source}:\n  ${problems.join("\n  ")}`,
    );
  return true;
}

module.exports = {
  stageFriends,
  embedFriends,
  friendsBundleProblems,
  checkFriendsBundle,
  STAGED,
};
