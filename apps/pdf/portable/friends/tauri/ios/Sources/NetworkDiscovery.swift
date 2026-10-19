// Nearby on the network for the core (ADR 0015 § 9): each entry the core registers is an NWListener of its own,
// advertised under the core's name with its TXT, and NWBrowser finds others; both include peer-to-peer Wi-Fi, which
// only these APIs reach. Connections in either direction cross into the core as streams. Browsing is what asks for
// Local Network access, and the core browses only once the person opened Friends.

import Foundation
import Network
import Tauri

struct NetworkEvent: Encodable {
  let kind: String
  var name: String?
  var txt: [[String]]?
  var peerToPeer: Bool?
  var stream: UInt64?
  var address: String?
  var dial: UInt64?
  var why: String?
}

/// DNS-SD's "the person refused Local Network access" (kDNSServiceErr_PolicyDenied).
private let policyDenied: Int32 = -65570

private func hex(_ text: String) -> String {
  text.utf8.map { String(format: "%02x", $0) }.joined()
}

private func isPeerToPeer(_ interfaces: [NWInterface]) -> Bool {
  !interfaces.isEmpty && interfaces.allSatisfy { $0.name.hasPrefix("awdl") || $0.name.hasPrefix("llw") }
}

final class NetworkDiscovery {
  private let queue = DispatchQueue(label: "szfriends.nearby.network")
  private var serviceType = "_szfriends._tcp"
  private var listeners: [String: NWListener] = [:]
  private var browser: NWBrowser?
  private var channel: Channel?
  private var endpoints: [String: NWEndpoint] = [:]

  private func parameters() -> NWParameters {
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    return parameters
  }

  private func send(_ event: NetworkEvent) {
    guard let channel = channel else { return }
    try? channel.send(event)
  }

  /// An entry the core named: a listener of its own; again with a new TXT on the same listener.
  func register(type: String, name: String, txt: [[String]]) throws {
    var fields: [String: String] = [:]
    for pair in txt where pair.count == 2 { fields[pair[0]] = pair[1] }
    let service = NWListener.Service(name: name, type: type, domain: nil, txtRecord: NWTXTRecord(fields))
    let listener: NWListener? = try queue.sync {
      if let listener = listeners[name] {
        listener.service = service
        return nil
      }
      let listener = try NWListener(using: parameters())
      listener.service = service
      listeners[name] = listener
      return listener
    }
    guard let started = listener else { return }
    started.newConnectionHandler = { [weak self] connection in self?.accepted(connection, entry: name) }
    started.start(queue: queue)
  }

  /// Off the air; still accepting until `unregister`, for someone who found it a moment ago.
  func withdraw(name: String) {
    queue.async { self.listeners[name]?.service = nil }
  }

  func unregister(name: String) {
    queue.async { self.listeners.removeValue(forKey: name)?.cancel() }
  }

  private func accepted(_ connection: NWConnection, entry: String) {
    guard let channel = channel else { return connection.cancel() }
    connection.start(queue: queue)
    var address: String?
    if case let .hostPort(host, _) = connection.endpoint { address = "\(host)" }
    let peerToPeer = isPeerToPeer(connection.currentPath?.availableInterfaces ?? [])
    let id = ConnectionEnd.add(connection, channel: channel)
    send(NetworkEvent(kind: "accepted", name: entry, peerToPeer: peerToPeer, stream: id, address: address))
  }

  func browse(type: String, channel: Channel) {
    queue.async {
      self.browser?.cancel()
      self.serviceType = type
      self.channel = channel
      let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: self.parameters())
      browser.stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready:
          self?.send(NetworkEvent(kind: "ready"))
        case let .waiting(error), let .failed(error):
          if case let .dns(code) = error, code == policyDenied {
            self?.send(NetworkEvent(kind: "denied"))
          } else {
            self?.send(NetworkEvent(kind: "failed", why: "\(error)"))
          }
        default:
          break
        }
      }
      browser.browseResultsChangedHandler = { [weak self] _, changes in
        for change in changes {
          switch change {
          case let .added(result), let .changed(_, result, _):
            self?.found(result)
          case let .removed(result):
            self?.lost(result)
          default:
            break
          }
        }
      }
      browser.start(queue: self.queue)
      self.browser = browser
    }
  }

  private func found(_ result: NWBrowser.Result) {
    guard case let .service(name, _, _, _) = result.endpoint, listeners[name] == nil else { return }
    var txt: [[String]] = []
    if case let .bonjour(record) = result.metadata {
      for (key, value) in record.dictionary { txt.append([key, hex(value)]) }
    }
    endpoints[name] = result.endpoint
    let peerToPeer = isPeerToPeer(result.interfaces)
    send(NetworkEvent(kind: "foundByPlatform", name: name, txt: txt, peerToPeer: peerToPeer))
  }

  private func lost(_ result: NWBrowser.Result) {
    guard case let .service(name, _, _, _) = result.endpoint else { return }
    endpoints[name] = nil
    send(NetworkEvent(kind: "lost", name: name))
  }

  /// A connection to a found instance, reported as opened with a stream, or with none after ten seconds.
  func connect(name: String, dial: UInt64) {
    queue.async {
      guard let channel = self.channel else { return }
      let endpoint = self.endpoints[name]
        ?? NWEndpoint.service(name: name, type: self.serviceType, domain: "local.", interface: nil)
      let connection = NWConnection(to: endpoint, using: self.parameters())
      var answered = false
      let answer: (UInt64?) -> Void = { [weak self] stream in
        if answered { return }
        answered = true
        self?.send(NetworkEvent(kind: "opened", stream: stream, dial: dial))
      }
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if !answered {
            connection.stateUpdateHandler = nil
            answer(ConnectionEnd.add(connection, channel: channel))
          }
        case .failed, .cancelled:
          answer(nil)
        default:
          break
        }
      }
      connection.start(queue: self.queue)
      self.queue.asyncAfter(deadline: .now() + 10) {
        if !answered {
          connection.cancel()
          answer(nil)
        }
      }
    }
  }

  func stop() {
    queue.async {
      self.browser?.cancel()
      self.browser = nil
      for listener in self.listeners.values { listener.cancel() }
      self.listeners.removeAll()
      self.endpoints.removeAll()
      self.channel = nil
    }
  }
}
