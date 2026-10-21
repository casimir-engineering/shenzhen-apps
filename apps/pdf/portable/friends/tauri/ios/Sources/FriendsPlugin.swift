// The Swift half of tauri-plugin-szfriends (ADR 0015 § 7, § 10, § 17). Rust calls it (src/phone/native.rs); the
// page never does. It starts nothing by itself: each command answers one call.
//
// - dirs, excludeFromBackup: Application Support, and Friends kept out of iCloud and computer backups.
// - keychainRead, keychainAdd, keychainDelete: the Friends key, a generic-password item readable after the first
//   unlock, on this device only, never synchronised.
// - share: a received file to the share sheet (Save to Files is one of its choices).
// - openUrl: a web or mail link, the app's page in Settings, or its notification settings.
// - notify*: Friends' notifications (Notifications.swift).
//
// It extends NearbyPlugin, whose commands it answers too: Tauri keeps one Swift plugin per Tauri plugin, and a second
// one registered for szfriends replaced the first.

import Foundation
import Security
import SwiftRs
import Tauri
import UIKit
import WebKit

struct KeyArgs: Decodable {
  let alias: String
  var data: String?
}

struct PathArgs: Decodable {
  let path: String
}

struct UrlArgs: Decodable {
  let url: String
}

/// The Keychain service every Friends item is filed under.
private let keychainService = "Shenzhen Friends"

private func hex(_ data: Data) -> String {
  data.map { String(format: "%02x", $0) }.joined()
}

private func unhex(_ text: String) -> Data? {
  guard text.count % 2 == 0 else { return nil }
  var data = Data(capacity: text.count / 2)
  var index = text.startIndex
  while index < text.endIndex {
    let next = text.index(index, offsetBy: 2)
    guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
    data.append(byte)
    index = next
  }
  return data
}

class FriendsPlugin: NearbyPlugin {

  @objc public func dirs(_ invoke: Invoke) throws {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    // What the person's other computers call this device: its name ("iPhone" without the name entitlement).
    invoke.resolve(["base": base.path, "name": UIDevice.current.name])
  }

  /// Sets the flag when it is missing and reads it back: called at every start, before Friends opens anything.
  @objc public func excludeFromBackup(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(PathArgs.self)
    var url = URL(fileURLWithPath: args.path, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      if try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
      }
      url.removeAllCachedResourceValues()
      let excluded = try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
      invoke.resolve(["done": excluded])
    } catch {
      invoke.resolve(["done": false])
    }
  }

  private func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
  }

  @objc public func keychainRead(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(KeyArgs.self)
    var request = query(args.alias)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data else { return invoke.reject("not data") }
      invoke.resolve(["secret": hex(data)])
    case errSecItemNotFound:
      invoke.resolve(["found": false])
    default:
      invoke.reject("keychain \(status)")
    }
  }

  @objc public func keychainAdd(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(KeyArgs.self)
    guard let secret = args.data.flatMap(unhex) else { return invoke.reject("no secret") }
    var item = query(args.alias)
    item[kSecValueData as String] = secret
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    invoke.resolve(["done": status == errSecSuccess])
  }

  @objc public func keychainDelete(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(KeyArgs.self)
    let status = SecItemDelete(query(args.alias) as CFDictionary)
    invoke.resolve(["done": status == errSecSuccess || status == errSecItemNotFound])
  }

  @objc public func share(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(PathArgs.self)
    let url = URL(fileURLWithPath: args.path)
    guard FileManager.default.isReadableFile(atPath: url.path) else { return invoke.resolve(["done": false]) }
    DispatchQueue.main.async {
      guard let presenter = self.manager.viewController else { return invoke.resolve(["done": false]) }
      let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      // iPad: the sheet points at the middle of the window.
      sheet.popoverPresentationController?.sourceView = presenter.view
      sheet.popoverPresentationController?.sourceRect = CGRect(
        x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
      sheet.popoverPresentationController?.permittedArrowDirections = []
      presenter.present(sheet, animated: true)
      invoke.resolve(["done": true])
    }
  }

  @objc public func openUrl(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(UrlArgs.self)
    let target: URL?
    if args.url == "app-settings:" {
      target = URL(string: UIApplication.openSettingsURLString)
    } else if args.url == "app-notification-settings:" {
      if #available(iOS 16.0, *) {
        target = URL(string: UIApplication.openNotificationSettingsURLString)
      } else {
        target = URL(string: UIApplication.openSettingsURLString)
      }
    } else if let url = URL(string: args.url), ["https", "http", "mailto"].contains(url.scheme ?? "") {
      target = url
    } else {
      target = nil
    }
    guard let url = target else { return invoke.resolve(["done": false]) }
    DispatchQueue.main.async {
      UIApplication.shared.open(url) { opened in invoke.resolve(["done": opened]) }
    }
  }
}

@_cdecl("init_plugin_szfriends")
public func initPlugin() -> Plugin {
  // Before the app finishes launching, so the tap that launched it is delivered.
  FriendsNotifications.shared.install()
  return FriendsPlugin()
}
