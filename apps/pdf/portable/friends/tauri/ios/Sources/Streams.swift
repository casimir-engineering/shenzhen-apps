// Byte streams the core reads and writes through the plugin: a network connection (NWConnection) or an L2CAP
// channel's streams. Each has an id; its bytes go to the core on the channel that opened or accepted it,
// base64-encoded, and the end follows the last of them.

import CoreBluetooth
import Foundation
import Network
import Tauri

struct StreamEvent: Encodable {
  let kind: String
  let stream: UInt64
  var data: String?
}

protocol StreamEnd: AnyObject {
  func write(_ data: Data)
  /// After everything already written.
  func close()
}

final class Streams {
  static let shared = Streams()
  private let lock = NSLock()
  private var next: UInt64 = 1
  private var open: [UInt64: StreamEnd] = [:]

  func reserve() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    let id = next
    next += 1
    return id
  }

  func add(_ id: UInt64, _ end: StreamEnd) {
    lock.lock()
    open[id] = end
    lock.unlock()
  }

  func remove(_ id: UInt64) {
    lock.lock()
    open[id] = nil
    lock.unlock()
  }

  func write(_ id: UInt64, _ data: Data) {
    lock.lock()
    let end = open[id]
    lock.unlock()
    end?.write(data)
  }

  func close(_ id: UInt64) {
    lock.lock()
    let end = open.removeValue(forKey: id)
    lock.unlock()
    end?.close()
  }

  func closeAll() {
    lock.lock()
    let ends = Array(open.values)
    open.removeAll()
    lock.unlock()
    for end in ends { end.close() }
  }
}

func sendBytes(_ channel: Channel, _ id: UInt64, _ data: Data) {
  try? channel.send(StreamEvent(kind: "bytes", stream: id, data: data.base64EncodedString()))
}

func sendClosed(_ channel: Channel, _ id: UInt64) {
  try? channel.send(StreamEvent(kind: "closed", stream: id, data: nil))
  Streams.shared.remove(id)
}

/// A network connection, already started on `queue`.
final class ConnectionEnd: StreamEnd {
  private let connection: NWConnection

  /// Registers the stream and starts reading.
  static func add(_ connection: NWConnection, channel: Channel) -> UInt64 {
    let id = Streams.shared.reserve()
    let end = ConnectionEnd(connection)
    Streams.shared.add(id, end)
    end.receive(id, channel)
    return id
  }

  private init(_ connection: NWConnection) {
    self.connection = connection
  }

  private func receive(_ id: UInt64, _ channel: Channel) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
      if let data = data, !data.isEmpty { sendBytes(channel, id, data) }
      if complete || error != nil {
        sendClosed(channel, id)
        self?.connection.cancel()
      } else {
        self?.receive(id, channel)
      }
    }
  }

  func write(_ data: Data) {
    connection.send(content: data, completion: .contentProcessed { _ in })
  }

  func close() {
    let done = NWConnection.SendCompletion.contentProcessed { _ in }
    connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: done)
  }
}

/// An L2CAP channel's Foundation streams, run on a thread of their own.
final class ChannelEnd: NSObject, StreamEnd, StreamDelegate {
  private let channelRef: CBL2CAPChannel
  private let id: UInt64
  private let events: Channel
  private var thread: Thread?
  private var pending = Data()
  private var closing = false
  private var ended = false

  static func add(_ l2cap: CBL2CAPChannel, channel: Channel) -> UInt64 {
    let id = Streams.shared.reserve()
    let end = ChannelEnd(l2cap, id: id, events: channel)
    Streams.shared.add(id, end)
    end.start()
    return id
  }

  private init(_ l2cap: CBL2CAPChannel, id: UInt64, events: Channel) {
    self.channelRef = l2cap
    self.id = id
    self.events = events
  }

  private func start() {
    let thread = Thread { [self] in
      let streams: [Stream?] = [channelRef.inputStream, channelRef.outputStream]
      for case let stream? in streams {
        stream.delegate = self
        stream.schedule(in: .current, forMode: .default)
        stream.open()
      }
      while !ended {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1))
      }
    }
    thread.name = "szfriends-l2cap-\(id)"
    self.thread = thread
    thread.start()
  }

  /// Runs `work` on the stream thread.
  private func onThread(_ work: @escaping () -> Void) {
    guard let thread = thread else { return }
    perform(#selector(run(_:)), on: thread, with: work as AnyObject, waitUntilDone: false)
  }

  @objc private func run(_ work: AnyObject) {
    (work as? () -> Void)?()
  }

  func write(_ data: Data) {
    onThread { [self] in
      pending.append(data)
      flush()
    }
  }

  func close() {
    onThread { [self] in
      closing = true
      flush()
    }
  }

  private func flush() {
    guard let output = channelRef.outputStream else { return finish() }
    while !pending.isEmpty && output.hasSpaceAvailable {
      let written = pending.withUnsafeBytes { bytes in
        output.write(bytes.bindMemory(to: UInt8.self).baseAddress!, maxLength: bytes.count)
      }
      if written <= 0 { break }
      pending.removeFirst(written)
    }
    if closing && pending.isEmpty { finish() }
  }

  /// Either side's end: the core hears it once either way.
  private func finish() {
    if ended { return }
    ended = true
    channelRef.inputStream?.close()
    channelRef.outputStream?.close()
    sendClosed(events, id)
  }

  func stream(_ stream: Stream, handle event: Stream.Event) {
    switch event {
    case .hasBytesAvailable:
      var buffer = [UInt8](repeating: 0, count: 65_536)
      let count = channelRef.inputStream?.read(&buffer, maxLength: buffer.count) ?? -1
      if count > 0 { sendBytes(events, id, Data(buffer[0..<count])) }
    case .hasSpaceAvailable:
      flush()
    case .endEncountered, .errorOccurred:
      finish()
    default:
      break
    }
  }
}
