// Loaded first by the main script of a Shenzhen 3D test copy (tools/updater-e2e/prep-3d-fixture.mjs), never by a
// release build: the copy runs under a profile of its own, so its single-instance lock, settings and Friends never
// meet those of a Shenzhen 3D installed on the same Mac. Electron keeps the single-instance lock in the profile folder.
// A test copy that the updater reopens after installing is started by launchd without the test's --user-data-dir; with
// the installed app's profile it would hold that app's lock, and the person's own Shenzhen 3D would quit at launch.
//
// The profile is the --user-data-dir the test passes, or else "szut-profile" beside the .app, inside the test's work
// directory. A profile made here starts with Friends off, so no Friends helper starts from it either.
const fs = require("node:fs");
const path = require("node:path");

const PROFILE_BESIDE_APP = "szut-profile";

function testProfile(argv, execPath) {
  const index = argv.findIndex(
    (a) => a === "--user-data-dir" || a.startsWith("--user-data-dir="),
  );
  const given =
    index < 0
      ? undefined
      : argv[index].includes("=")
        ? argv[index].slice("--user-data-dir=".length)
        : argv[index + 1];
  if (given) return { profile: path.resolve(given), given: true };
  // <dir>/Shenzhen 3D.app/Contents/MacOS/Shenzhen 3D -> <dir>/szut-profile
  const bundle = path.resolve(execPath, "../../..");
  return {
    profile: path.join(path.dirname(bundle), PROFILE_BESIDE_APP),
    given: false,
  };
}

function isolate(app, argv = process.argv, execPath = process.execPath) {
  const { profile, given } = testProfile(argv, execPath);
  fs.mkdirSync(profile, { recursive: true });
  const friends = path.join(profile, "friends.json");
  if (!given && !fs.existsSync(friends))
    fs.writeFileSync(friends, JSON.stringify({ enabled: false }));
  // Before main.cjs runs: it asks for the single-instance lock as it loads, and it only moves to an older profile
  // when the current one does not exist, which this one now does.
  app.setPath("userData", profile);
  return profile;
}

module.exports = { PROFILE_BESIDE_APP, testProfile, isolate };

if (process.versions.electron && process.type === "browser")
  isolate(require("electron").app);
