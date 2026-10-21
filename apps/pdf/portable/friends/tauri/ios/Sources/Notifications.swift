// Friends' notifications on iOS (ADR 0017): local notifications only, posted while the app runs or in the short time
// iOS gives it in the background. The core decides what notifies (src/phone/notify.rs) and FriendsPlugin's notify*
// commands post it here. Nothing is asked at launch: authorization is requested only when the person taps Turn On
// (allow_notifications). A tap opens the request's URL (`<scheme>://friends/conversation/<id>`) the way a Friends
// link opens the app, and its key goes to the core. Whether a message shows while the app is in front was decided by
// the core (the focused conversation does not notify), so whatever arrives here is shown.

import Foundation
import Tauri
import UIKit
import UserNotifications

struct NotifySetupArgs: Decodable {
  let channel: Channel
}

struct NotifyOpenArgs: Decodable {
  let url: String
}

struct NotifyPostArgs: Decodable {
  let key: String
  let kind: String
  let thread: String
  let title: String
  let body: String
  let open: NotifyOpenArgs
}

struct NotifyThreadArgs: Decodable {
  let thread: String
}

struct NotifyEvent: Encodable {
  let kind: String
  var key: String?
  var state: String?
}

/// The notification centre's delegate, set when the plugin registers, before the app finishes launching, so a tap that
/// launched the app reaches it.
final class FriendsNotifications: NSObject, UNUserNotificationCenterDelegate {
  static let shared = FriendsNotifications()

  private let lock = NSLock()
  private var channel: Channel?
  /// Taps that came before the core was there to hear them.
  private var pending: [NotifyEvent] = []
  private var reported: String?

  func install() {
    UNUserNotificationCenter.current().delegate = self
  }

  func attach(_ channel: Channel) {
    lock.lock()
    self.channel = channel
    let waiting = pending
    pending = []
    lock.unlock()
    for event in waiting { try? channel.send(event) }
  }

  func send(_ event: NotifyEvent) {
    lock.lock()
    guard let channel = channel else {
      pending.append(event)
      lock.unlock()
      return
    }
    lock.unlock()
    try? channel.send(event)
  }

  static func state(_ settings: UNNotificationSettings) -> String {
    switch settings.authorizationStatus {
    case .notDetermined: return "not_asked"
    case .denied: return "denied"
    default: return "granted"
    }
  }

  /// Tells the core the permission when it changed (an answer, or a switch flipped in Settings).
  func report(always: Bool = false) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let state = FriendsNotifications.state(settings)
      self.lock.lock()
      let changed = always || state != self.reported
      self.reported = state
      self.lock.unlock()
      if changed { self.send(NotifyEvent(kind: "permission", state: state)) }
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let text = info["url"] as? String, let url = URL(string: text)
    {
      send(NotifyEvent(kind: "open", key: response.notification.request.identifier))
      // The app's own scheme: iOS hands it to the app as it hands a Friends link (RunEvent::Opened).
      DispatchQueue.main.async { UIApplication.shared.open(url) }
    }
    completionHandler()
  }
}

extension FriendsPlugin {
  /// The core started: where taps and permission changes go.
  @objc public func notifySetup(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(NotifySetupArgs.self)
    FriendsNotifications.shared.attach(args.channel)
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      invoke.resolve(["permission": FriendsNotifications.state(settings)])
      FriendsNotifications.shared.report(always: true)
    }
  }

  @objc public func notifyPermission(_ invoke: Invoke) throws {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      invoke.resolve(["permission": FriendsNotifications.state(settings)])
    }
  }

  /// Turn On (allow_notifications): the system's own prompt; the answer arrives as a permission event.
  @objc public func notifyAsk(_ invoke: Invoke) throws {
    NSLog("FRIENDS-NOTIFY asking")
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      // In the log for the simulator's check (phones-notify-ios.mjs): asked once, on Turn On.
      NSLog("FRIENDS-NOTIFY asked granted=%@", granted ? "true" : "false")
      FriendsNotifications.shared.report()
    }
    invoke.resolve(["done": true])
  }

  @objc public func notifyPost(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(NotifyPostArgs.self)
    let content = UNMutableNotificationContent()
    content.title = args.title
    content.body = args.body
    content.threadIdentifier = args.thread
    content.sound = .default
    content.userInfo = ["url": args.open.url, "kind": args.kind]
    let request = UNNotificationRequest(identifier: args.key, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { error in
      NSLog("FRIENDS-NOTIFY posted %@ kind=%@ added=%@", args.key, args.kind, error == nil ? "true" : "false")
      invoke.resolve(["done": error == nil])
    }
  }

  @objc public func notifyWithdraw(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(NotifyThreadArgs.self)
    let center = UNUserNotificationCenter.current()
    center.getDeliveredNotifications { delivered in
      let keys = delivered.filter { $0.request.content.threadIdentifier == args.thread }.map { $0.request.identifier }
      center.removeDeliveredNotifications(withIdentifiers: keys)
      invoke.resolve(["done": true])
    }
  }

  /// Android's switch; an iPhone has no such thing (Settings says so).
  @objc public func notifyBackground(_ invoke: Invoke) throws {
    invoke.resolve(["done": false])
  }
}
