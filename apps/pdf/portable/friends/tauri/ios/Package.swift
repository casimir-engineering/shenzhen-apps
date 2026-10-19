// swift-tools-version:5.5
// The Swift half of tauri-plugin-szfriends (ADR 0015 § 7, § 9, § 10, § 17): the Keychain item that holds the Friends
// key, Friends kept out of backups, the share sheet and links (FriendsPlugin); nearby discovery with NWListener,
// NWBrowser and NWConnection (peer-to-peer Wi-Fi included) and Bluetooth with CoreBluetooth (NearbyPlugin).

import PackageDescription

let package = Package(
  name: "tauri-plugin-szfriends",
  platforms: [
    .macOS(.v10_13),
    .iOS(.v15),
  ],
  products: [
    .library(
      name: "tauri-plugin-szfriends",
      type: .static,
      targets: ["tauri-plugin-szfriends"])
  ],
  dependencies: [
    .package(name: "Tauri", path: "../.tauri/tauri-api")
  ],
  targets: [
    .target(
      name: "tauri-plugin-szfriends",
      dependencies: [
        .byName(name: "Tauri")
      ],
      path: "Sources")
  ]
)
