// The plugin's iOS side (tauri/src/nearby.rs): the commands the core calls, which return at once, and the channels
// on which NetworkDiscovery and BluetoothRadio report. Local Network access is asked by browsing and Bluetooth access
// by powering up, and the core does either only once the person opened Friends. The app's Info.plist carries
// NSLocalNetworkUsageDescription, NSBonjourServices (_szfriends._tcp) and NSBluetoothAlwaysUsageDescription.

import Foundation
import Tauri

struct RegisterArgs: Decodable {
  let serviceType: String
  let name: String
  let port: UInt16
  let txt: [[String]]
}

struct NameArgs: Decodable {
  let name: String
}

struct BrowseArgs: Decodable {
  let serviceType: String
  let channel: Channel
}

struct ConnectArgs: Decodable {
  let name: String
  let dial: UInt64
}

struct ChannelArgs: Decodable {
  let channel: Channel
}

struct AdvertiseArgs: Decodable {
  let presence: String
  let `public`: String?
}

struct PublishArgs: Decodable {
  let `public`: Bool
}

struct PsmArgs: Decodable {
  let psm: UInt16
}

struct PeripheralArgs: Decodable {
  let peripheral: String
  let `public`: Bool
}

struct OpenArgs: Decodable {
  let peripheral: String
  let psm: UInt16
  let dial: UInt64
}

struct StreamArgs: Decodable {
  let stream: UInt64
  let data: String?
}

private func bytes(_ hex: String) -> Data {
  var data = Data()
  var index = hex.startIndex
  while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), index != hex.endIndex {
    if let byte = UInt8(hex[index..<next], radix: 16) { data.append(byte) }
    index = next
  }
  return data
}

/// FriendsPlugin extends it: Tauri keeps one Swift plugin per Tauri plugin, so Nearby answers through that one.
class NearbyPlugin: Plugin {
  private let network = NetworkDiscovery()
  private let radio = BluetoothRadio()

  @objc public func nearbyCapabilities(_ invoke: Invoke) {
    invoke.resolve(["ownsConnections": true, "bluetooth": true])
  }

  @objc public func nearbyRegister(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(RegisterArgs.self)
    try network.register(type: args.serviceType, name: args.name, txt: args.txt)
    invoke.resolve()
  }

  @objc public func nearbyWithdraw(_ invoke: Invoke) throws {
    network.withdraw(name: try invoke.parseArgs(NameArgs.self).name)
    invoke.resolve()
  }

  @objc public func nearbyUnregister(_ invoke: Invoke) throws {
    network.unregister(name: try invoke.parseArgs(NameArgs.self).name)
    invoke.resolve()
  }

  @objc public func nearbyBrowse(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(BrowseArgs.self)
    network.browse(type: args.serviceType, channel: args.channel)
    invoke.resolve()
  }

  @objc public func nearbyConnect(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(ConnectArgs.self)
    network.connect(name: args.name, dial: args.dial)
    invoke.resolve()
  }

  @objc public func nearbyStop(_ invoke: Invoke) {
    network.stop()
    invoke.resolve()
  }

  @objc public func radioPermission(_ invoke: Invoke) {
    invoke.resolve(["permission": BluetoothRadio.permission])
  }

  @objc public func radioPowerUp(_ invoke: Invoke) throws {
    radio.powerUp(channel: try invoke.parseArgs(ChannelArgs.self).channel)
    invoke.resolve()
  }

  @objc public func radioPowerDown(_ invoke: Invoke) {
    radio.powerDown()
    invoke.resolve()
  }

  @objc public func radioStartScanning(_ invoke: Invoke) {
    radio.startScanning()
    invoke.resolve()
  }

  @objc public func radioStopScanning(_ invoke: Invoke) {
    radio.stopScanning()
    invoke.resolve()
  }

  @objc public func radioAdvertise(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(AdvertiseArgs.self)
    radio.advertise(presence: bytes(args.presence), publicValue: args.public.map(bytes))
    invoke.resolve()
  }

  @objc public func radioStopAdvertising(_ invoke: Invoke) {
    radio.stopAdvertising()
    invoke.resolve()
  }

  @objc public func radioPublish(_ invoke: Invoke) throws {
    radio.publish(public: try invoke.parseArgs(PublishArgs.self).public)
    invoke.resolve()
  }

  @objc public func radioUnpublish(_ invoke: Invoke) throws {
    radio.unpublish(psm: try invoke.parseArgs(PsmArgs.self).psm)
    invoke.resolve()
  }

  @objc public func radioRead(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(PeripheralArgs.self)
    radio.read(peripheral: args.peripheral, public: args.public)
    invoke.resolve()
  }

  @objc public func radioOpen(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(OpenArgs.self)
    radio.open(peripheral: args.peripheral, psm: args.psm, dial: args.dial)
    invoke.resolve()
  }

  @objc public func streamWrite(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(StreamArgs.self)
    Streams.shared.write(args.stream, Data(base64Encoded: args.data ?? "") ?? Data())
    invoke.resolve()
  }

  @objc public func streamClose(_ invoke: Invoke) throws {
    Streams.shared.close(try invoke.parseArgs(StreamArgs.self).stream)
    invoke.resolve()
  }
}
