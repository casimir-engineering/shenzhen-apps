# Shenzhen 3D 0.2.11

- Friends (Beta): files no longer copy between your computers and phones by themselves. Choose **Download here** on the ones you want.
- Friends (Beta): faster transfers, and Bluetooth between an Android phone and a Mac is several times faster.
- Friends (Beta): direct connections over the internet work behind more VPNs and routers.

## New in this version

### Friends (Beta)

- **Download here.** A file on one of your computers or phones, one you sent to You there or one a friend sent there, still shows on your other devices right away, but it no longer copies to them by itself. Choose **Download here** on each device where you want it. On the device that has the file, it says whether your other devices can download it, shows the progress while one of them does, and says **On all your computers** once they all have it. A copy that was under way when you update waits for **Download here**, then carries on from where it stopped. Your devices that haven't updated yet still copy files by themselves.
- **Faster transfers.** Sending and receiving take less of the processor and wait less for the disk, on every platform, so files move faster over a fast network or a cable. The gain is largest with friends who have updated too.
- **Faster Bluetooth between Android and the Mac.** Between an Android phone and a Mac, files over Bluetooth now go several times faster, in both directions. Friends now says **Bluetooth LE** wherever it names this connection.
- **Direct Wi-Fi only when you're off Wi-Fi.** Friends no longer opens a direct Wi-Fi link beside the Wi-Fi network a device is on, which slowed that network: a file to a friend on the same Wi-Fi now goes over the network alone, at its full speed. Direct Wi-Fi is used only when neither of you is on a Wi-Fi network, for example both on a cable, and only with friends who have updated too. When only Bluetooth reaches a friend, a phone online over mobile data can still leave its Wi-Fi for about a minute to send a large file over direct Wi-Fi; it always asks you first.
- **Direct connections through VPNs.** Direct connections over the internet now form in more cases where a VPN or a router got in the way, instead of going through the much slower relay. While a Mac uses a VPN, its direct connection to a friend or to your other devices goes around the VPN, so the friend, and the Friends server that helps you connect, see your network's own internet address. If the VPN doesn't allow anything to go around it, Friends connects through it as before.

## Updating

- **Mac, Windows, Linux and Android.** Shenzhen 3D finds this update by itself and asks before installing it. With the Linux `.deb` or `.rpm`, it tells you the update is out and **Download** gets it for you to install.
- **iPhone and iPad.** Shenzhen 3D tells you when a new version is out. It installs only on the iPhones and iPads registered for testing.

## Downloads

- **Mac** (Apple Silicon, macOS 13 or later): `Shenzhen-3D-0.2.11-Apple-Silicon.dmg`. Open it and drag Shenzhen 3D into Applications.
- **Windows** (x64): `Shenzhen-3D-0.2.11-Windows-x64-Setup.exe`, or the `.msi`. They are not signed, so Windows may warn you before it installs them.
- **Linux** (ARM64): the `.AppImage`, `.deb` or `.rpm`.
- **Android** (ARM64): `shenzhen-3d-0.2.11-android-arm64-development.apk` installs directly; Android asks you to allow apps from this source first. The `.aab` is for publishing to a store and is not signed.
- **iPhone and iPad**: `shenzhen-3d-0.2.11-ios-registered-devices.ipa` installs only on the devices registered for testing. `shenzhen-3d-0.2.11-ios-arm64-simulator.tar.gz` runs in Xcode's iOS Simulator.
- **Browser**: unzip `shenzhen-3d-0.2.11-web.zip` and serve the folder over HTTP or HTTPS.

Friends (Beta) is in every version except the browser one.

`SHA256SUMS.txt` lists the SHA-256 of every file here.

Shenzhen 3D is free software, under the GNU General Public License version 3 or later.
