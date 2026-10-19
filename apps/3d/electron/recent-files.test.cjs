const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");
const { createRecentFileStore } = require("./recent-files.cjs");
async function fixture(t) {
  const directory = await fs.mkdtemp(
    path.join(os.tmpdir(), "shenzhen-recent-test-"),
  );
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  return { directory, profile: path.join(directory, "profile") };
}
test("authorized files and companions reopen through a fresh process store without renderer paths", async (t) => {
  const { directory, profile } = await fixture(t);
  const files = ["part.obj", "paint.mtl", "texture.png"];
  for (const name of files)
    await fs.writeFile(path.join(directory, name), name);
  const entry = await createRecentFileStore(profile).remember(
    files.map((name) => path.join(directory, name)),
    "part.obj",
    "obj",
  );
  assert.equal(entry.paths, undefined);
  assert.equal(entry.fileCount, 3);
  const restarted = createRecentFileStore(profile);
  assert.deepEqual(await restarted.list(), [entry]);
  assert.equal((await restarted.touch(entry.id)).id, entry.id);
  await assert.rejects(restarted.touch("ungranted"), /unavailable/);
  const reopened = await restarted.open(entry.id);
  assert.deepEqual(
    reopened.map((f) => f.name),
    files,
  );
  assert.deepEqual(
    reopened.map((f) => Buffer.from(f.bytes).toString()),
    files,
  );
  assert.equal(
    (await fs.stat(path.join(profile, "recent-file-grants.json"))).mode & 0o777,
    0o600,
  );
  await assert.rejects(
    restarted.open(path.join(directory, "part.obj")),
    /Invalid recent file grant/,
  );
  await assert.rejects(restarted.open("a".repeat(36)), /unavailable/);
});
test("same basenames keep distinct grants and concurrent remember operations retain both", async (t) => {
  const { directory, profile } = await fixture(t);
  const paths = [
    path.join(directory, "first", "part.step"),
    path.join(directory, "second", "part.step"),
  ];
  for (const [i, file] of paths.entries()) {
    await fs.mkdir(path.dirname(file));
    await fs.writeFile(file, String(i));
  }
  const store = createRecentFileStore(profile);
  const entries = await Promise.all(
    paths.map((file) => store.remember([file], "part.step", "step")),
  );
  assert.notEqual(entries[0].id, entries[1].id);
  assert.equal((await store.list()).length, 2);
  assert.equal(
    (await store.remember([paths[0]], "part.step", "step")).id,
    entries[0].id,
  );
  assert.equal((await store.list()).length, 2);
});
test("missing files and symlink replacements fail explicitly instead of reading another path", async (t) => {
  const { directory, profile } = await fixture(t);
  const file = path.join(directory, "part.stl"),
    other = path.join(directory, "other.stl");
  await fs.writeFile(file, "authorized");
  await fs.writeFile(other, "not authorized");
  const store = createRecentFileStore(profile),
    entry = await store.remember([file], "part.stl", "stl");
  await fs.rm(file);
  await assert.rejects(store.open(entry.id), /moved, removed/);
  await fs.symlink(other, file);
  await assert.rejects(store.open(entry.id), /moved, removed/);
  await store.remove(entry.id);
  assert.deepEqual(await store.list(), []);
});
test("recent grants are bounded and reject directories or unsupported request shapes", async (t) => {
  const { directory, profile } = await fixture(t),
    store = createRecentFileStore(profile);
  await assert.rejects(store.remember([directory], "folder", "step"));
  await assert.rejects(
    store.remember(["relative.step"], "relative.step", "step"),
  );
  for (let i = 0; i < 10; i++) {
    const file = path.join(directory, `${i}.step`);
    await fs.writeFile(file, String(i));
    await store.remember([file], `${i}.step`, "step");
  }
  assert.deepEqual(
    (await store.list()).map((e) => e.name),
    [
      "9.step",
      "8.step",
      "7.step",
      "6.step",
      "5.step",
      "4.step",
      "3.step",
      "2.step",
    ],
  );
});
