// Bluetooth for the core (ADR 0004, ADR 0015 § 9) with CoreBluetooth, as the Mac helper's radio does it
// (SZFriendsCoreBluetoothRadio.m): advertise the Friends service, serve the presence characteristics, scan, read each
// device's values in one short connection, and publish, accept and open L2CAP channels. Creating the managers is
// what asks for Bluetooth access, and the core powers up only once the person opened Friends or allowed it before.

import CoreBluetooth
import Foundation
import Tauri

private let serviceID = CBUUID(string: "22FB96F7-C35A-45B5-9673-1CAC64EC8E75")
private let publicID = CBUUID(string: "C8B26601-A773-4E6D-BC10-BA6F596D92C1")
private let presenceID = CBUUID(string: "9F2BC83C-9A97-49C4-9F30-19D368A135BA")
private let publicCharacteristicID = CBUUID(string: "E66577A2-9C37-4D7B-876E-03127666B7DA")

struct RadioEvent: Encodable {
  let kind: String
  var power: String?
  var peripheral: String?
  var `public`: Bool?
  var value: String?
  var publicValue: String?
  var psm: UInt16?
  var stream: UInt64?
  var peer: String?
  var dial: UInt64?
}

private func hex(_ data: Data?) -> String? {
  data.map { $0.map { String(format: "%02x", $0) }.joined() }
}

private final class Read {
  let wantsPublic: Bool
  var value: Data?
  var publicValue: Data?
  var done = false
  init(wantsPublic: Bool) { self.wantsPublic = wantsPublic }
}

final class BluetoothRadio: NSObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate, CBPeripheralDelegate {
  private let queue = DispatchQueue(label: "szfriends.nearby.bluetooth")
  private var central: CBCentralManager?
  private var manager: CBPeripheralManager?
  private var channel: Channel?
  private var presence = Data()
  private var publicValue: Data?
  private var serviceAdded = false
  private var advertising = false
  private var advertisedPublic = false
  private var scanning = false
  private var publishing: [Bool] = []
  private var published: [CBL2CAPPSM: Bool] = [:]
  private var known: [UUID: CBPeripheral] = [:]
  private var reads: [UUID: Read] = [:]
  private var opens: [UUID: [(psm: CBL2CAPPSM, dial: UInt64)]] = [:]
  /// Open channels per peripheral: its connection stays while any is open.
  private var channels: [UUID: Int] = [:]

  /// Reading it creates no manager and never asks.
  static var permission: String {
    switch CBManager.authorization {
    case .allowedAlways: return "allowed"
    case .denied, .restricted: return "denied"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
  }

  private func send(_ event: RadioEvent) {
    guard let channel = channel else { return }
    try? channel.send(event)
  }

  func powerUp(channel: Channel) {
    queue.async {
      self.channel = channel
      let quiet = [CBCentralManagerOptionShowPowerAlertKey: false]
      self.central = CBCentralManager(delegate: self, queue: self.queue, options: quiet)
      self.manager = CBPeripheralManager(
        delegate: self, queue: self.queue, options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
    }
  }

  func powerDown() {
    queue.async {
      self.central?.stopScan()
      for peripheral in self.known.values { self.central?.cancelPeripheralConnection(peripheral) }
      self.manager?.stopAdvertising()
      self.manager?.removeAllServices()
      for psm in self.published.keys { self.manager?.unpublishL2CAPChannel(psm) }
      Streams.shared.closeAll()
      self.central = nil
      self.manager = nil
      self.channel = nil
      self.forget()
    }
  }

  private func forget() {
    serviceAdded = false
    advertising = false
    scanning = false
    publishing.removeAll()
    published.removeAll()
    reads.removeAll()
    opens.removeAll()
    channels.removeAll()
  }

  // MARK: - Power

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    let power: String
    switch central.state {
    case .poweredOn: power = "on"
    case .poweredOff: power = "off"
    case .unauthorized: power = "unauthorized"
    case .unsupported: power = "unsupported"
    default: power = "unknown"
    }
    if central.state != .poweredOn { forget() }
    send(RadioEvent(kind: "power", power: power))
  }

  func peripheralManagerDidUpdateState(_ manager: CBPeripheralManager) {
    guard manager.state == .poweredOn, !serviceAdded else { return }
    let service = CBMutableService(type: serviceID, primary: true)
    service.characteristics = [presenceID, publicCharacteristicID].map {
      CBMutableCharacteristic(type: $0, properties: .read, value: nil, permissions: .readable)
    }
    manager.add(service)
    serviceAdded = true
    if !presence.isEmpty { startAdvertising() }
  }

  // MARK: - Advertising and reads of ours

  func advertise(presence: Data, publicValue: Data?) {
    queue.async {
      self.presence = presence
      self.publicValue = publicValue
      if !self.advertising || self.advertisedPublic != (publicValue != nil) { self.startAdvertising() }
    }
  }

  private func startAdvertising() {
    guard let manager = manager, manager.state == .poweredOn else { return }
    manager.stopAdvertising()
    let uuids = publicValue == nil ? [serviceID] : [serviceID, publicID]
    manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: uuids])
    advertising = true
    advertisedPublic = publicValue != nil
  }

  func stopAdvertising() {
    queue.async {
      self.manager?.stopAdvertising()
      self.advertising = false
    }
  }

  func peripheralManager(_ manager: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    let value = request.characteristic.uuid == presenceID ? presence : (publicValue ?? Data())
    guard request.offset <= value.count else { return manager.respond(to: request, withResult: .invalidOffset) }
    request.value = value.subdata(in: request.offset..<value.count)
    manager.respond(to: request, withResult: .success)
  }

  // MARK: - Channels of ours

  func publish(public: Bool) {
    queue.async {
      guard let manager = self.manager, manager.state == .poweredOn else {
        return self.send(RadioEvent(kind: "published", public: `public`, psm: 0))
      }
      self.publishing.append(`public`)
      manager.publishL2CAPChannel(withEncryption: false)
    }
  }

  func peripheralManager(_ manager: CBPeripheralManager, didPublishL2CAPChannel psm: CBL2CAPPSM, error: Error?) {
    let isPublic = publishing.isEmpty ? false : publishing.removeFirst()
    if error == nil { published[psm] = isPublic }
    send(RadioEvent(kind: "published", public: isPublic, psm: error == nil ? psm : 0))
  }

  func unpublish(psm: UInt16) {
    queue.async {
      self.published[psm] = nil
      self.manager?.unpublishL2CAPChannel(psm)
    }
  }

  func peripheralManager(_ manager: CBPeripheralManager, didOpen l2cap: CBL2CAPChannel?, error: Error?) {
    guard let l2cap = l2cap, let channel = channel, error == nil else { return }
    let id = ChannelEnd.add(l2cap, channel: channel)
    let isPublic = published[l2cap.psm] ?? false
    send(RadioEvent(kind: "accepted", public: isPublic, stream: id, peer: l2cap.peer.identifier.uuidString))
  }

  // MARK: - Scanning

  func startScanning() {
    queue.async {
      guard let central = self.central, central.state == .poweredOn else { return }
      let once = [CBCentralManagerScanOptionAllowDuplicatesKey: false]
      // Either UUID: a visible Android phone advertises the public UUID first and the service UUID only in its
      // scan response, which a scan without duplicates may never report.
      central.scanForPeripherals(withServices: [serviceID, publicID], options: once)
      self.scanning = true
    }
  }

  func stopScanning() {
    queue.async {
      self.central?.stopScan()
      self.scanning = false
    }
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any],
    rssi: NSNumber
  ) {
    var uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
    uuids += advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
    known[peripheral.identifier] = peripheral
    let isPublic = uuids.contains(publicID)
    send(RadioEvent(kind: "discovered", peripheral: peripheral.identifier.uuidString, public: isPublic))
  }

  private func peripheral(_ id: String) -> CBPeripheral? {
    guard let uuid = UUID(uuidString: id) else { return nil }
    if let known = known[uuid] { return known }
    let found = central?.retrievePeripherals(withIdentifiers: [uuid]).first
    if let found = found { known[uuid] = found }
    return found
  }

  // MARK: - Reads of theirs

  func read(peripheral id: String, public wantsPublic: Bool) {
    queue.async {
      guard let central = self.central, let peripheral = self.peripheral(id) else {
        return self.send(RadioEvent(kind: "read", peripheral: id))
      }
      let read = Read(wantsPublic: wantsPublic)
      self.reads[peripheral.identifier] = read
      peripheral.delegate = self
      if peripheral.state == .connected {
        peripheral.discoverServices([serviceID])
      } else {
        central.connect(peripheral)
      }
      self.queue.asyncAfter(deadline: .now() + 10) { self.finishRead(peripheral) }
    }
  }

  private func finishRead(_ peripheral: CBPeripheral) {
    guard let read = reads[peripheral.identifier], !read.done else { return }
    read.done = true
    reads[peripheral.identifier] = nil
    if channels[peripheral.identifier, default: 0] == 0 && opens[peripheral.identifier] == nil {
      central?.cancelPeripheralConnection(peripheral)
    }
    send(RadioEvent(
      kind: "read", peripheral: peripheral.identifier.uuidString, value: hex(read.value),
      publicValue: hex(read.publicValue)))
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.delegate = self
    if reads[peripheral.identifier] != nil { peripheral.discoverServices([serviceID]) }
    for open in opens[peripheral.identifier] ?? [] { peripheral.openL2CAPChannel(open.psm) }
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    failAll(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    channels[peripheral.identifier] = nil
    failAll(peripheral)
  }

  private func failAll(_ peripheral: CBPeripheral) {
    finishRead(peripheral)
    for open in opens.removeValue(forKey: peripheral.identifier) ?? [] {
      send(RadioEvent(kind: "opened", dial: open.dial))
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
      return finishRead(peripheral)
    }
    peripheral.discoverCharacteristics([presenceID, publicCharacteristicID], for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard let read = reads[peripheral.identifier] else { return }
    let characteristics = service.characteristics ?? []
    guard let presence = characteristics.first(where: { $0.uuid == presenceID }) else {
      return finishRead(peripheral)
    }
    peripheral.readValue(for: presence)
    if read.wantsPublic, let publicOne = characteristics.first(where: { $0.uuid == publicCharacteristicID }) {
      peripheral.readValue(for: publicOne)
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard let read = reads[peripheral.identifier] else { return }
    if error != nil { return finishRead(peripheral) }
    if characteristic.uuid == presenceID { read.value = characteristic.value ?? Data() }
    if characteristic.uuid == publicCharacteristicID { read.publicValue = characteristic.value ?? Data() }
    if read.value != nil && (!read.wantsPublic || read.publicValue != nil) { finishRead(peripheral) }
  }

  // MARK: - Channels of theirs

  func open(peripheral id: String, psm: UInt16, dial: UInt64) {
    queue.async {
      guard let central = self.central, let peripheral = self.peripheral(id) else {
        return self.send(RadioEvent(kind: "opened", dial: dial))
      }
      peripheral.delegate = self
      self.opens[peripheral.identifier, default: []].append((psm: psm, dial: dial))
      if peripheral.state == .connected {
        peripheral.openL2CAPChannel(psm)
      } else {
        central.connect(peripheral)
      }
      self.queue.asyncAfter(deadline: .now() + 10) {
        guard var waiting = self.opens[peripheral.identifier],
          let index = waiting.firstIndex(where: { $0.dial == dial })
        else { return }
        waiting.remove(at: index)
        self.opens[peripheral.identifier] = waiting.isEmpty ? nil : waiting
        self.send(RadioEvent(kind: "opened", dial: dial))
      }
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didOpen l2cap: CBL2CAPChannel?, error: Error?) {
    guard var waiting = opens[peripheral.identifier], !waiting.isEmpty else { return }
    let psm = l2cap?.psm
    let index = waiting.firstIndex(where: { $0.psm == psm }) ?? 0
    let open = waiting.remove(at: index)
    opens[peripheral.identifier] = waiting.isEmpty ? nil : waiting
    guard let l2cap = l2cap, let channel = channel, error == nil else {
      return send(RadioEvent(kind: "opened", dial: open.dial))
    }
    channels[peripheral.identifier, default: 0] += 1
    let id = ChannelEnd.add(l2cap, channel: channel)
    send(RadioEvent(kind: "opened", stream: id, dial: open.dial))
  }
}
