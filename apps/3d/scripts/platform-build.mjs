#!/usr/bin/env node
import { copyFileSync, existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { delimiter, dirname, resolve } from 'node:path';

// Reproducible platform entry point; credentials stay in the caller's environment.
const platform = process.argv[2] ?? 'desktop';
// --friends: Shenzhen Friends in the desktop packages (docs/FRIENDS.md § Tauri).
const friends = process.argv.includes('--friends');
const extra = process.argv.slice(3).filter((arg) => arg !== '--friends');
// rustup owns cross-compilation targets even when package-manager Rust is earlier on PATH.
if (platform !== 'web') {
  const rustc = spawnSync('rustup', ['which', 'rustc'], { encoding: 'utf8' });
  if (rustc.status === 0) process.env.PATH = dirname(rustc.stdout.trim()) + delimiter + process.env.PATH;
}
const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
const npmRun = (...args) =>
  spawnSync(npm, args, { stdio: 'inherit', env: process.env, shell: process.platform === 'win32' }).status ?? 1;
const run = (...args) => {
  const status = npmRun(...args);
  if (status !== 0) process.exit(status);
};
// The pinned plugin and helper, staged by scripts/friends/setup-tauri-friends.mjs; the --config that points the
// `friends` feature at the plugin. A Friends build resolves more crates than src-tauri/Cargo.lock holds, so it builds
// --locked with src-tauri/friends/Cargo.lock, made from the pin by the plugin's tools/host-build.sh (docs/FRIENDS.md
// § Locked builds), in Cargo.lock's place; Cargo.lock is put back afterwards, so builds without Friends keep the
// placeholder.
const friendsLock = 'src-tauri/friends/Cargo.lock';
function friendsArguments() {
  const setup = (...args) =>
    spawnSync(process.execPath, ['scripts/friends/setup-tauri-friends.mjs', ...args], { encoding: 'utf8' });
  const phone = platform === 'android' || platform === 'ios';
  const check = setup('--check', ...(phone ? ['--phones'] : []));
  if (check.status !== 0) {
    process.stderr.write(check.stderr);
    process.exit(1);
  }
  const config = setup('--print-config').stdout.trim();
  const plugin = setup('--print-plugin').stdout.trim();
  if (!existsSync(friendsLock)) {
    console.error(`error: ${friendsLock} is missing: make it with ${plugin}/tools/host-build.sh lock src-tauri ${friendsLock}`);
    process.exit(1);
  }
  // Where bash runs, the lock is checked against the pin first, which says how to make it again; --locked alone
  // (Windows) refuses the same lock, in cargo's words.
  if (process.platform !== 'win32') {
    const fits = spawnSync('bash', [`${plugin}/tools/host-build.sh`, 'check', 'src-tauri', friendsLock], { stdio: 'inherit' });
    if (fits.status !== 0) process.exit(1);
  }
  // Phones run the core in the app (the plugin's embedded mode), online included: the plugin, the usage
  // descriptions on iOS, and the core's phone.toml (the bundled SQLite's flags, ADR 0015 § 12) beside Friends' size
  // profile.
  if (phone) {
    const tauri = ['--features', 'friends-online', '--config', 'src-tauri/friends/phones.conf.json'];
    // Absolute: cargo runs from the Android or Xcode project, and takes a path it cannot find for a key.
    const cargo = ['--locked', '--config', config, '--config', resolve('src-tauri/friends/phones-profile.toml')];
    return { tauri, cargo: [...cargo, '--config', resolve(plugin, '../core-rs/phone.toml')] };
  }
  // A Mac embeds the Objective-C helper in Contents/Helpers; Windows and Linux carry the Rust helper beside the app.
  const conf = process.platform === 'darwin' ? 'src-tauri/friends/mac.conf.json' : 'src-tauri/friends/tauri.conf.json';
  const tauri = ['--features', 'friends', '--config', conf];
  return { tauri, cargo: ['--locked', '--config', config] };
}
if (platform === 'web') run('run', 'build');
else if (friends) {
  const { tauri, cargo } = friendsArguments();
  // Put back afterwards: Cargo.lock, the iOS project's Info.plist, into which the build merges Friends' keys, and
  // the Android manifest, to which it adds the intent filter for Friends links.
  const kept = [
    'src-tauri/Cargo.lock',
    'src-tauri/gen/apple/shenzhen-3d_iOS/Info.plist',
    'src-tauri/gen/android/app/src/main/AndroidManifest.xml',
  ].filter(existsSync);
  for (const file of kept) copyFileSync(file, `${file}.friends-backup`);
  copyFileSync(friendsLock, 'src-tauri/Cargo.lock');
  if (platform === 'android') {
    // Friends links: the intent filter, written every time (scripts/friends/android-links.mjs says why).
    const { withLinkFilters } = await import('./friends/android-links.mjs');
    const manifest = 'src-tauri/gen/android/app/src/main/AndroidManifest.xml';
    const { mobile } = JSON.parse(readFileSync('src-tauri/friends/phones.conf.json', 'utf8')).plugins['deep-link'];
    writeFileSync(manifest, withLinkFilters(readFileSync(manifest, 'utf8'), mobile));
  }
  const command = platform === 'desktop' ? ['build'] : [platform, 'build'];
  const status = npmRun('run', 'tauri', '--', ...command, ...tauri, ...extra, '--', ...cargo);
  for (const file of kept) {
    copyFileSync(`${file}.friends-backup`, file);
    rmSync(`${file}.friends-backup`);
  }
  if (status !== 0) process.exit(status);
} else if (platform === 'desktop') run('run', 'tauri', '--', 'build', ...extra);
else if (platform === 'android' || platform === 'ios') {
  const generated = platform === 'android' ? 'src-tauri/gen/android' : 'src-tauri/gen/apple';
  if (!existsSync(generated)) run('run', 'tauri', '--', platform, 'init', '--ci');
  run('run', 'tauri', '--', platform, 'build', ...extra);
} else {
  console.error('Usage: node scripts/platform-build.mjs web|desktop|android|ios [--friends] [Tauri build flags]');
  process.exit(2);
}
