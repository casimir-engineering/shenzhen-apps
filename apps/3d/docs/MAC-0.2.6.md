# Shenzhen 3D 0.2.6

- See how each file travels: icons for each way it's using, and a bar showing how much each one carried, with size, percentage, speed and time left.
- Friends always tries a direct connection first and switches off the relay as soon as one works.

## New in this version

### Friends (Beta)

- **See how each file travels.** While a file goes or arrives, its row shows an icon for each way it's using, such as the same Wi-Fi, Bluetooth or the relay, and a bar split by how much each one carried. Under the bar: the size, percentage and speed, the time left, and a line such as "Via Same Wi-Fi + Bluetooth". A file copied from two of your own computers at once says "From 2 of your computers".
- **The relay only as a last resort.** Friends always tries a direct connection first. A file that starts through the relay moves to a direct connection, such as the same Wi-Fi or Bluetooth, within about a second of one working. A file that starts on a direct connection never moves to the relay while that connection works.

## Also in the last release (0.2.5)

- **Friends (Beta): faster transfers** that use several connections at once and pick up where they stopped.
- **Friends (Beta): each friend's latest message** in the list.
- **Android: Go faster?** When only Bluetooth reaches a friend, a large file can go over direct Wi-Fi instead.

### Friends (Beta)

- **Faster transfers.** When your friend also has the latest Shenzhen 3D, ShenzhenPDF or Shenzhen Files:
  - files go over every connection you share at once, such as your network and Bluetooth. Bluetooth only ever helps: if it drops out, the file doesn't pause;
  - a connection that goes quiet is noticed within seconds, and the file carries on from exactly where it was;
  - **Get again** and copies between your own devices pick up where they stopped, even after a restart, and take the file from every device that has it, at once;
  - many small files sent together arrive many times faster.
- **Nothing sent twice.** A file a friend already sent you isn't sent again, and a new version of it brings only what changed.
- **Finishing….** After a large file arrives, its row says "Finishing…" while the file is checked, before it's saved.
- **Latest message in the list.** Each friend's row shows the latest message or file in your conversation, such as "Mei: how are you?" or "You: 📎 bracket.step", instead of how you're connected. The icons still show how a friend nearby is reached.

### Android

- **Go faster over direct Wi-Fi** (Android 13 and later). When a friend nearby is reached only over Bluetooth and isn't on your Wi-Fi, a large file can go over a direct Wi-Fi link between your phone and their device instead. If that means leaving your Wi-Fi for a moment, the file's row asks **Go faster?** first, and your phone rejoins its Wi-Fi by itself when it's done. **Not now** keeps the file on Bluetooth.

## Updating

- **Mac, Windows, Linux and Android.** Shenzhen 3D 0.2.5 finds this update by itself and asks before installing it. With the Linux `.deb` or `.rpm`, it tells you the update is out and **Download** gets it for you to install.
- **iPhone and iPad.** Shenzhen 3D 0.2.5 tells you when a new version is out. It installs only on the iPhones and iPads registered for testing.

## Downloads

- **Mac** (Apple Silicon, macOS 13 or later): `Shenzhen-3D-0.2.6-Apple-Silicon.dmg`. Open it and drag Shenzhen 3D into Applications.
- **Windows** (x64): `Shenzhen-3D-0.2.6-Windows-x64-Setup.exe`, or the `.msi`. They are not signed, so Windows may warn you before it installs them.
- **Linux** (ARM64): the `.AppImage`, `.deb` or `.rpm`.
- **Android** (ARM64): `shenzhen-3d-0.2.6-android-arm64-development.apk` installs directly; Android asks you to allow apps from this source first. The `.aab` is for publishing to a store and is not signed.
- **iPhone and iPad**: `shenzhen-3d-0.2.6-ios-registered-devices.ipa` installs only on the devices registered for testing. `shenzhen-3d-0.2.6-ios-arm64-simulator.tar.gz` runs in Xcode's iOS Simulator.
- **Browser**: unzip `shenzhen-3d-0.2.6-web.zip` and serve the folder over HTTP or HTTPS.

Friends (Beta) is in every version except the browser one.

`SHA256SUMS.txt` lists the SHA-256 of every file here.

Shenzhen 3D is free software, under the GNU General Public License version 3 or later.
