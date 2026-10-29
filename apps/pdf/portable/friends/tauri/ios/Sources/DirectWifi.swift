// The Wi-Fi Direct boost on iOS (ADR 0019; the core's side is szfriends-helper's nearby/direct_wifi.rs, bridged in
// tauri/src/nearby.rs). An iPhone cannot host a link; it joins the one a friend's Android phone hosts, as an ordinary
// WPA2 network, with NEHotspotConfiguration (joinOnce), which shows the system's own "Wants to Join Wi-Fi Network"
// prompt every time. Leaving it is removing that configuration, after which iOS goes back to the network it was on
// by itself. Needs the Hotspot Configuration entitlement (com.apple.developer.networking.HotspotConfiguration) in the
// app's profile. Never reads the current network's name (that needs location): the question says "your Wi-Fi".

import Foundation
import Network
import NetworkExtension

final class DirectWifi {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "szfriends.direct-wifi")
  private var path: Network.NWPath?

  init() {
    monitor.pathUpdateHandler = { [weak self] path in self?.path = path }
    monitor.start(queue: queue)
  }

  /// On Wi-Fi, on mobile data, on a cable, as the system's path monitor says (no traffic of ours).
  func connectivity() -> (onWifi: Bool, mobile: Bool, wired: Bool) {
    let path = queue.sync { self.path ?? monitor.currentPath }
    let interfaces = path.availableInterfaces.map(\.type)
    return (interfaces.contains(.wifi), interfaces.contains(.cellular), interfaces.contains(.wiredEthernet))
  }

  func online() -> Bool {
    let path = queue.sync { self.path ?? monitor.currentPath }
    return path.status == .satisfied
  }

  /// Joins `network` once (the system asks the person); whether it is on it now.
  func join(network: String, passphrase: String, done: @escaping (Bool) -> Void) {
    let configuration = NEHotspotConfiguration(ssid: network, passphrase: passphrase, isWEP: false)
    configuration.joinOnce = true
    NEHotspotConfigurationManager.shared.apply(configuration) { error in
      guard let error = error as NSError? else { return done(true) }
      done(error.domain == NEHotspotConfigurationErrorDomain
        && error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue)
    }
  }

  /// Leaves `joined`: iOS then rejoins the network it was on by itself.
  func leave(joined: String, done: @escaping (Bool) -> Void) {
    NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: joined)
    // Give the system a moment to move back before the core checks it is online again.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { done(true) }
  }
}
