// The Swift half of tauri-plugin-szfriends (ADR 0015 § 7, § 10, § 17). Rust calls it (src/phone/native.rs); the
// page never does. It starts nothing by itself: each command answers one call.
//
// - dirs, excludeFromBackup: Application Support, and Friends kept out of iCloud and computer backups.
// - keychainRead, keychainAdd, keychainDelete: the Friends key, a generic-password item readable after the first
//   unlock, on this device only, never synchronised.
// - share: a received file to the share sheet (Save to Files is one of its choices).
// - pickFiles: Attach files, the system's document picker for any type, several at once; the system copies each file
//   as it reads it and the copies move into the folder Rust names.
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
import UniformTypeIdentifiers
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

struct FolderArgs: Decodable {
  let folder: String
}

/// A name a file can have here, as the person saw it: no folder separators, no leading dot, at most 200 bytes.
func plainFileName(_ raw: String) -> String {
  var name = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\0", with: "")
  while name.hasPrefix(".") { name.removeFirst() }
  name = name.trimmingCharacters(in: .whitespaces)
  if name.isEmpty { name = "File" }
  while name.utf8.count > 200 {
    let ext = (name as NSString).pathExtension
    var base = (name as NSString).deletingPathExtension
    base.removeLast()
    name = ext.isEmpty || ext.utf8.count > 16 ? String((name).dropLast()) : base + "." + ext
  }
  return name
}

/// Attach files: the picker's answer, the chosen copies moved into `folder/<n>/<name>`.
final class FilePicking: NSObject, UIDocumentPickerDelegate {
  let invoke: Invoke
  let folder: URL
  var done: (() -> Void)?

  init(invoke: Invoke, folder: URL) {
    self.invoke = invoke
    self.folder = folder
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    var files: [[String: String]] = []
    for (index, url) in urls.prefix(100).enumerated() {
      let directory = folder.appendingPathComponent(String(index), isDirectory: true)
      let target = directory.appendingPathComponent(plainFileName(url.lastPathComponent))
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: target)
        files.append(["path": target.path])
      } catch {
        try? FileManager.default.removeItem(at: directory)
      }
    }
    invoke.resolve(["files": files])
    done?()
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    invoke.resolve([:])
    done?()
  }
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
  /// Attach files while its picker is up.
  private var picking: FilePicking?

  @objc public func pickFiles(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(FolderArgs.self)
    let folder = URL(fileURLWithPath: args.folder, isDirectory: true)
    DispatchQueue.main.async {
      guard let presenter = self.manager.viewController else { return invoke.resolve([:]) }
      // asCopy: the system copies each chosen file for this app as it reads it, whatever app or service holds it.
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item], asCopy: true)
      picker.allowsMultipleSelection = true
      let picking = FilePicking(invoke: invoke, folder: folder)
      picking.done = { [weak self] in self?.picking = nil }
      self.picking = picking
      picker.delegate = picking
      presenter.present(picker, animated: true)
    }
  }

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
