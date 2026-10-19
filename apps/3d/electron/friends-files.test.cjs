// The helper files the Friends panel may read (files.cjs), friends.lock (lock.cjs), and how the host finds a helper
// and reads its version (host.cjs). No helper runs here; electron/friends-smoke.mjs drives a real one.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fsp = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const {
  readHelperImage,
  createAnimalSet,
  classifyPath,
  jpegSize,
} = require("./friends/files.cjs");
const fs = require("node:fs");
const {
  friendsMode,
  parseFriendsLock,
  readFriendsLock,
} = require("./friends/lock.cjs");
const { locateFriends, readHelperInfo } = require("./friends/host.cjs");

const root = path.resolve(__dirname, "..");

function png(width, height) {
  const bytes = Buffer.alloc(64);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(bytes);
  bytes.write("IHDR", 12, "latin1");
  bytes.writeUInt32BE(width, 16);
  bytes.writeUInt32BE(height, 20);
  return bytes;
}

test("previews and photos are read only from the helper's own folders, as small files of stated size", async (t) => {
  const state = await fsp.mkdtemp(path.join(os.tmpdir(), "szf3d-files-"));
  t.after(() => fsp.rm(state, { recursive: true, force: true }));
  await fsp.mkdir(path.join(state, "thumbnails/sub"), { recursive: true });
  await fsp.mkdir(path.join(state, "pictures"));
  const thumb = path.join(state, "thumbnails/a.png");
  await fsp.writeFile(thumb, png(136, 192));
  const read = (kind, file, width, height) =>
    readHelperImage(state, kind, file, { width, height });
  assert.equal((await read("thumbnail", thumb, 136, 192)).width, 136);
  assert.equal(
    await read("thumbnail", thumb, 100, 192),
    null,
    "a different size than the snapshot said",
  );
  assert.equal(await read("picture", thumb), null, "a preview is not a photo");
  await fsp.writeFile(path.join(state, "thumbnails/sub/b.png"), png(10, 10));
  assert.equal(
    await read("thumbnail", path.join(state, "thumbnails/sub/b.png"), 10, 10),
    null,
    "subfolder",
  );
  assert.equal(
    await read(
      "thumbnail",
      `${state}/thumbnails/../thumbnails/a.png`,
      136,
      192,
    ),
    null,
    "dot-dot",
  );
  assert.equal(
    await read("thumbnail", `${state}/thumbnails//a.png`, 136, 192),
    null,
    "doubled slash",
  );
  await fsp.symlink(thumb, path.join(state, "thumbnails/link.png"));
  assert.equal(
    await read("thumbnail", path.join(state, "thumbnails/link.png"), 136, 192),
    null,
    "a link is not followed",
  );
  execFileSync("mkfifo", [path.join(state, "thumbnails/fifo.png")]);
  assert.equal(
    await read("thumbnail", path.join(state, "thumbnails/fifo.png"), 1, 1),
    null,
    "a FIFO never blocks",
  );
  await fsp.writeFile(
    path.join(state, "pictures/big.png"),
    Buffer.concat([png(256, 256), Buffer.alloc(300 * 1024)]),
  );
  assert.equal(
    await read("picture", path.join(state, "pictures/big.png")),
    null,
    "over 256 KiB",
  );
  await fsp.writeFile(path.join(state, "pictures/huge.png"), png(5000, 5000));
  assert.equal(
    await read("picture", path.join(state, "pictures/huge.png")),
    null,
    "over 1024 px",
  );
  const jpeg = Buffer.from([
    0xff, 0xd8, 0xff, 0xe0, 0, 4, 0, 0, 0xff, 0xc0, 0, 11, 8, 0, 200, 1, 0, 3,
    0, 0, 0, 0,
  ]);
  assert.deepEqual(jpegSize(jpeg), {
    type: "image/jpeg",
    width: 256,
    height: 200,
  });
  await fsp.writeFile(path.join(state, "pictures/me.jpg"), jpeg);
  assert.equal(
    (await read("picture", path.join(state, "pictures/me.jpg"))).height,
    200,
  );
  assert.equal(await read("thumbnail", "/etc/hosts", 1, 1), null);
  assert.equal(await classifyPath(state), "folder");
  assert.equal(await classifyPath(thumb), "file");
  assert.equal(
    await classifyPath(path.join(state, "thumbnails/link.png")),
    "other",
  );
  assert.equal(await classifyPath(path.join(state, "missing")), "missing");
});

test("the animal set comes from its manifest, and names outside svg/ are refused", async (t) => {
  const directory = await fsp.mkdtemp(path.join(os.tmpdir(), "szf3d-animals-"));
  t.after(() => fsp.rm(directory, { recursive: true, force: true }));
  await fsp.mkdir(path.join(directory, "svg"));
  await fsp.writeFile(path.join(directory, "svg/00-goose.svg"), "<svg/>");
  await fsp.writeFile(
    path.join(directory, "manifest.json"),
    JSON.stringify({
      set: 1,
      animals: [
        { index: 0, name: "Goose", color: "#5a4a7a", svg: "svg/00-goose.svg" },
        { index: 1, name: "Bad", svg: "../manifest.json" },
      ],
    }),
  );
  const set = createAnimalSet(directory);
  assert.deepEqual(await set.animal(1, 0), {
    svg: "<svg/>",
    color: "#5a4a7a",
    name: "Goose",
  });
  assert.equal(await set.animal(1, 1), null);
  assert.equal(await set.animal(2, 0), null, "another set");
  assert.equal((await set.list()).animals.length, 2);
});

// What the setup script reads, in the given mode: "<mode> <commit> <number> <version> <bundle> <core commit>".
const shellLock = (mode) =>
  execFileSync(
    "bash",
    [
      "-c",
      '. scripts/friends/friends-lock.sh && friends_lock_read "$PWD" && echo "$FRIENDS_MODE $FRIENDS_COMMIT ' +
        "$FRIENDS_BUILD_NUMBER $FRIENDS_SHORT_VERSION $FRIENDS_BUNDLE_VERSION $FRIENDS_CORE_COM" +
        'MIT"',
    ],
    {
      cwd: root,
      encoding: "utf8",
      env: { ...process.env, SZF_FRIENDS_ROOT: "", SZF_FRIENDS_MODE: mode },
    },
  )
    .trim()
    .split(/ +/)
    .join(" ");
const nodeLock = (lock) =>
  [
    lock.mode,
    lock.commit ?? "",
    lock.buildNumber,
    lock.shortVersion,
    lock.bundleVersion,
    lock.coreCommit ?? "",
  ]
    .join(" ")
    .trim()
    .split(/ +/)
    .join(" ");

test("friends.lock reads the same in Node and in the setup script", () => {
  const lock = readFriendsLock(root, { SZF_FRIENDS_MODE: "pinned" });
  assert.equal(lock.commit.length, 40);
  assert.equal(shellLock("pinned"), nodeLock(lock));
  const base = "url=u\ncommit=" + "a".repeat(40) + "\n";
  assert.throws(
    () => parseFriendsLock(base + "helper_build_number=26131101\n"),
    /YYMMDDBB/,
  );
  assert.throws(
    () => parseFriendsLock(base + "helper_build_number=26101101\ncommit=b\n"),
    /second time/,
  );
  assert.throws(
    () =>
      parseFriendsLock(base + "helper_build_number=26101101\n$(rm -rf /)\n"),
    /not key=value/,
  );
  assert.throws(
    () => parseFriendsLock(base + "helper_build_number=26101101\nextra=1\n"),
    /unknown key/,
  );
  assert.throws(
    () =>
      parseFriendsLock(
        base + "helper_build_number=26101101\ncore_commit=abc\n",
      ),
    /core_commit/,
  );
  assert.equal(
    parseFriendsLock(base + "helper_build_number=26101101\n").coreCommit,
    null,
  );
});

// In the Shenzhen repository (apps/3d beside apps/pdf) Friends comes from apps/pdf, with ShenzhenPDF's version keys.
test(
  "Friends from the same tree reads the same in Node and in the setup script",
  { skip: !fs.existsSync(path.join(root, "../pdf/portable/friends")) },
  () => {
    const lock = readFriendsLock(root, { SZF_FRIENDS_MODE: "tree" });
    assert.equal(lock.mode, "tree");
    assert.equal(lock.commit, null);
    assert.match(String(lock.buildNumber), /^\d{8}$/);
    assert.equal(shellLock("tree"), nodeLock(lock));
    assert.equal(
      friendsMode(root, { SZF_FRIENDS_ROOT: "/elsewhere" }),
      "pinned",
    );
  },
);

test("the helper's version and build come from its Info.plist; a missing one never wins a handover", async (t) => {
  const app = await fsp.mkdtemp(path.join(os.tmpdir(), "szf3d-helper-"));
  t.after(() => fsp.rm(app, { recursive: true, force: true }));
  await fsp.mkdir(path.join(app, "Contents"));
  await fsp.writeFile(
    path.join(app, "Contents/Info.plist"),
    "<plist><dict><key>CFBundleShortVersionString</key>\n<string>26.10.11</string><key>" +
      "CFBundleVersion</key><string>26101101</string></dict></plist>",
  );
  assert.deepEqual(readHelperInfo(app), {
    version: "26.10.11",
    buildNumber: 26101101,
  });
  assert.deepEqual(readHelperInfo(path.join(app, "missing")), {
    version: "0",
    buildNumber: 0,
  });
});

test("a development run offers Friends only with a helper and a Friends home of its own", () => {
  const app = { isPackaged: false };
  assert.equal(locateFriends({ app, env: {}, platform: "darwin" }), null);
  assert.equal(
    locateFriends({
      app,
      env: { SHENZHEN_3D_FRIENDS_HELPER: "/x/Shenzhen Friends.app" },
      platform: "darwin",
    }),
    null,
  );
  assert.ok(
    locateFriends({
      app,
      env: {
        SHENZHEN_3D_FRIENDS_HELPER: "/x/Shenzhen Friends.app",
        SZFRIENDS_STATE_DIR: "/tmp/h",
      },
      platform: "darwin",
    }),
  );
  assert.equal(
    locateFriends({ app: { isPackaged: true }, env: {}, platform: "linux" }),
    null,
  );
  const packaged = locateFriends({
    app: { isPackaged: true },
    env: {},
    platform: "darwin",
    resourcesPath: "/A.app/Contents/Resources",
  });
  assert.equal(
    packaged.helperExecutable,
    "/A.app/Contents/Helpers/Shenzhen Friends.app/Contents/MacOS/Shenzhen Friends",
  );
  assert.equal(packaged.animals, "/A.app/Contents/Resources/Friends/animals");
});
