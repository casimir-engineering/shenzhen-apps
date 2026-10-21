// Updater tests never take an installed Shenzhen 3D's identity, and nothing they start outlives them.
// electron/test-identity.cjs, tools/updater-e2e/sweep.py and the scripts that use them.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const { isolate, testProfile } = require("./test-identity.cjs");

const repo = path.resolve(__dirname, "../../..");
const read = (file) => fs.readFileSync(path.join(repo, file), "utf8");
const sweep = path.join(repo, "tools/updater-e2e/sweep.py");
const realProfile = path.join(
  os.homedir(),
  "Library/Application Support/Shenzhen 3D",
);

test("a test copy reopened without arguments gets a profile beside its .app, with Friends off", () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "szut-identity-"));
  try {
    const exe = path.join(work, "relaunch/Shenzhen 3D.app/Contents/MacOS/Shenzhen 3D");
    const calls = [];
    const profile = isolate({ setPath: (...a) => calls.push(a) }, [exe], exe);
    assert.equal(profile, path.join(work, "relaunch/szut-profile"));
    assert.deepEqual(calls, [["userData", profile]]);
    assert.notEqual(profile, realProfile);
    assert.ok(fs.statSync(profile).isDirectory(), "main.cjs moves to an older profile only when this one is missing");
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(profile, "friends.json"), "utf8")), { enabled: false });
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
});

test("a test copy launched by the test keeps the test's --user-data-dir", () => {
  const exe = "/w/install/Shenzhen 3D.app/Contents/MacOS/Shenzhen 3D";
  assert.deepEqual(testProfile([exe, "--user-data-dir=/w/profile"], exe), { profile: "/w/profile", given: true });
  assert.deepEqual(testProfile([exe, "--user-data-dir", "/w/p2"], exe), { profile: "/w/p2", given: true });
});

test("test copies load the test identity before the release main asks for the single-instance lock", () => {
  const prep = read("tools/updater-e2e/prep-3d-fixture.mjs");
  assert.match(prep, /electron\/test-identity\.cjs"\), path\.join\(tmp, "electron\/szut-identity\.cjs"\)/);
  const main = /'require\("\.\/szut-hook\.cjs"\);\\nrequire\("\.\/szut-identity\.cjs"\);\\nrequire\("\.\/main\.cjs"\);\\n'/;
  assert.match(prep, main, "szut-main.cjs: the hook, then the identity, then main.cjs");
  assert.match(prep, /pkg\.main = "electron\/szut-main\.cjs"/);
});

test("release builds never honour a test identity", () => {
  const main = read("apps/3d/electron/main.cjs");
  assert.doesNotMatch(main, /test-identity|szut/);
  assert.match(main, /app\.requestSingleInstanceLock\(\)/);
  // The older-profile move that could otherwise replace the test profile only happens when it does not exist.
  assert.match(main, /!fs\.existsSync\(app\.getPath\("userData"\)\) && fs\.existsSync\(previousProfile\)/);
});

test("every Mac updater test launches with its own profile and ends what it started by path", () => {
  for (const file of ["tools/updater-e2e/update-e2e-3d.mjs", "apps/3d/electron/update-install-smoke.mjs"]) {
    const source = read(file);
    assert.match(source, /`--user-data-dir=\$\{profile\}`/, file);
    assert.match(source, /sweep\.py/, file);
    assert.match(source, /process\.on\("exit"/, file);
    assert.match(source, /"SIGTERM"/, file);
    assert.doesNotMatch(source, /pkill|killall/, file);
  }
  const mac = read("tools/updater-e2e/mac-update-e2e.py");
  assert.match(mac, /sweep\.py/);
  assert.match(mac, /finally:\n\s+if WORK and end_leftovers\(WORK\)/);
  assert.match(read("tools/release/common.py"), /def end_test_processes/);
  for (const file of ["tools/release/app_3d.py", "tools/release/macshared.py"])
    assert.match(read(file), /finally:\n\s+end_test_processes\(/, file);
});

test("sweep.py ends a process left under a test directory, by path, and leaves others alone", { skip: process.platform !== "darwin" }, async () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "szut-sweep-"));
  const outside = spawn("/bin/sleep", ["60"], { stdio: "ignore" });
  let left;
  try {
    const macos = path.join(work, "relaunch/Shenzhen 3D.app/Contents/MacOS");
    fs.mkdirSync(macos, { recursive: true });
    const exe = path.join(macos, "Shenzhen 3D");
    fs.copyFileSync("/bin/sleep", exe);
    fs.chmodSync(exe, 0o755);
    // As the updater reopens an app: detached, its command line naming nothing of the test.
    left = spawn(exe, ["60"], { detached: true, stdio: "ignore" });
    left.unref();
    await new Promise((resolve) => setTimeout(resolve, 300));
    const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };
    const run = (...args) => spawnSync("python3", ["-I", sweep, ...args], { encoding: "utf8" });

    const listed = run(work);
    assert.equal(listed.status, 1, listed.stdout + listed.stderr);
    assert.match(listed.stdout, new RegExp(`still running: ${left.pid} `));
    assert.ok(alive(left.pid), "without --kill nothing is ended");

    const ended = run("--kill", work);
    assert.equal(ended.status, 1, "a leftover fails the run even when it was ended");
    assert.match(ended.stdout, /ended/);
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.ok(!alive(left.pid));
    assert.ok(alive(outside.pid), "a process outside the test directory is untouched");

    assert.equal(run("--kill", work).status, 0, "nothing left");
    assert.equal(run("--kill", "/Applications").status, 2, "refuses where installed apps live");
    assert.equal(run("--kill", os.homedir()).status, 2);
  } finally {
    outside.kill();
    if (left?.pid) try { process.kill(left.pid, "SIGKILL"); } catch {}
    fs.rmSync(work, { recursive: true, force: true });
  }
});
