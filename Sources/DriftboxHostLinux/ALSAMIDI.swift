#if os(Linux)
  import CALSABridge
  import DriftboxHost
  import DriftboxSeq
  import Foundation
  import Glibc
  import Synchronization

  public struct ALSAMIDIError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
  }

  /// ALSA sequencer ports for the shared session. One worker owns the sequencer, discovers
  /// ports, receives messages and sends queued output on HostTime's monotonic clock.
  public final class ALSAMIDI: MIDIInputPort, MIDIOutputPort, Sendable {
    private let core: Core

    /// `connectsInputs: false` publishes ports without automatically subscribing to sources.
    /// This is useful for a software peer in integration tests; the desktop uses true.
    public init(name: String = "Driftbox", connectsInputs: Bool = true) throws {
      core = try Core(name: name, connectsInputs: connectsInputs)
      let thread = Thread { [core] in core.run() }
      thread.name = "Driftbox ALSA MIDI"
      thread.start()
    }
    deinit { core.stop() }
    /// Finish output already due, discard future output, and wait for the worker to close.
    /// Called from a MIDI callback, this requests shutdown without waiting on itself.
    public func stop() { core.stop() }

    public var sources: [String] { core.state.withLock { $0.inputs.keys.sorted() } }
    public var destinations: [String] { core.state.withLock { $0.outputs.keys.sorted() } }
    public var offersVirtualSource: Bool { core.state.withLock { $0.running } }
    public var error: String? { core.state.withLock { $0.error } }
    public var ignoring: Set<String> {
      get { core.state.withLock { $0.ignoring } }
      set { core.state.withLock { $0.ignoring = newValue } }
    }
    public var onNote: (@Sendable (Int, Double) -> Void)? {
      get { core.state.withLock { $0.onNote } }
      set { core.state.withLock { $0.onNote = newValue } }
    }
    public var onMessage: (@Sendable ([UInt8]) -> Void)? {
      get { core.state.withLock { $0.onMessage } }
      set { core.state.withLock { $0.onMessage = newValue } }
    }
    public var onClock: (@Sendable (ClockMessage, Double) -> Void)? {
      get { core.state.withLock { $0.onClock } }
      set { core.state.withLock { $0.onClock = newValue } }
    }
    public var onSourcesChange: (@Sendable ([String]) -> Void)? {
      get { core.state.withLock { $0.onSourcesChange } }
      set { core.state.withLock { $0.onSourcesChange = newValue } }
    }

    public func send(_ bytes: [UInt8], to destination: MIDIDestination, at hostTime: UInt64) -> Bool {
      guard Self.valid(bytes) else { return false }
      return core.state.withLock { state in
        guard state.running else { return false }
        let name: String
        switch destination {
        case .virtual: name = ""  // Published names are never empty.
        case .port(let port):
          guard state.outputs[port] != nil else { return false }
          name = port
        }
        // Bound memory if a caller schedules indefinitely into the future.
        guard state.pending < 16_384 else { return false }
        state.queue.add(bytes, to: name, at: hostTime)
        state.pending += 1
        state.counts[name, default: 0] += 1
        db_midi_wake(core.handle)
        return true
      }
    }
    public func flush(_ destination: MIDIDestination) {
      core.state.withLock { state in
        let name: String
        switch destination {
        case .virtual: name = ""
        case .port(let port): name = port
        }
        // The same lock covers delivery, so nothing already taken from the queue can escape
        // after flush returns. Keep a per-destination count without exposing queue internals.
        state.drop(name)
      }
    }

    static func valid(_ bytes: [UInt8]) -> Bool {
      guard let status = bytes.first else { return false }
      let count: Int
      switch status {
      case 0x80...0xBF, 0xE0...0xEF, 0xF2: count = 3
      case 0xC0...0xDF, 0xF1, 0xF3: count = 2
      case 0xF6, 0xF8, 0xFA...0xFC, 0xFE...0xFF: count = 1
      default: return false
      }
      return bytes.count == count && bytes.dropFirst().allSatisfy { $0 < 0x80 }
    }

    private struct Address: Hashable, Sendable {
      let client: Int32
      let port: Int32
    }
    private struct Port {
      let address: Address
      let name: String
      let flags: Int32
    }
    private final class Collector { var ports: [Port] = [] }
    private struct State {
      var running = true
      var stopAt: UInt64?
      var error: String?
      var inputs: [String: Address] = [:]
      var outputs: [String: Address] = [:]
      var ignoring: Set<String> = []
      var queue = MIDIQueue<[UInt8]>()
      var pending = 0
      var counts: [String: Int] = [:]
      var onNote: (@Sendable (Int, Double) -> Void)?
      var onMessage: (@Sendable ([UInt8]) -> Void)?
      var onClock: (@Sendable (ClockMessage, Double) -> Void)?
      var onSourcesChange: (@Sendable ([String]) -> Void)?

      mutating func drop(_ name: String) {
        queue.drop(name)
        pending -= counts.removeValue(forKey: name) ?? 0
      }
    }

    // The opaque handle belongs to the worker; initialization precedes thread start. Other
    // threads only write the eventfd while holding state, which also serializes final close.
    private final class Core: @unchecked Sendable {
      let handle: OpaquePointer
      let state = Mutex(State())
      private let connectsInputs: Bool
      private var connected: Set<Address> = []
      // Keep a retired source's name until its exit announcement is consumed: its final
      // MIDI Stop may already be queued ahead of that announcement when discovery runs.
      private var sourceNames: [Address: String] = [:]
      private let finished = DispatchGroup()
      private let workerKey = "driftbox-midi-" + UUID().uuidString

      init(name: String, connectsInputs: Bool) throws {
        self.connectsInputs = connectsInputs
        var error = [CChar](repeating: 0, count: 512)
        guard let handle = db_midi_open(name, &error, error.count) else {
          throw ALSAMIDIError(
            String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        self.handle = handle
        refresh()
        finished.enter()
      }
      func stop() {
        state.withLock { state in
          if state.running {
            state.running = false
            state.stopAt = HostTime.now()
            db_midi_wake(handle)
          }
        }
        // A callback may release the last public owner on this very worker.
        if Thread.current.threadDictionary[workerKey] == nil { finished.wait() }
      }
      private func refresh() {
        let collector = Collector()
        let result = db_midi_ports(handle, Unmanaged.passUnretained(collector).toOpaque()) {
          context, client, port, clientName, portName, flags in
          guard let context, let clientName, let portName else { return }
          let name = String(cString: clientName) + ": " + String(cString: portName)
          Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue().ports.append(
            Port(address: Address(client: client, port: port), name: name, flags: flags))
        }
        guard result >= 0 else {
          fail("ALSA MIDI discovery failed (\(result))")
          return
        }
        var inputs: [String: Address] = [:]
        var outputs: [String: Address] = [:]
        var used: Set<String> = []
        for port in collector.ports {
          var name = port.name
          var index = 2
          while used.contains(name) {
            name = "\(port.name) (\(index))"
            index += 1
          }
          used.insert(name)
          if port.flags & 1 != 0 { inputs[name] = port.address }
          if port.flags & 2 != 0 { outputs[name] = port.address }
        }
        for (name, address) in inputs { sourceNames[address] = name }
        let wanted = connectsInputs ? Set(inputs.values) : []
        for address in connected.subtracting(wanted) {
          _ = db_midi_connect(handle, address.client, address.port, 0)
          connected.remove(address)
        }
        for address in wanted.subtracting(connected) {
          let result = db_midi_connect(handle, address.client, address.port, 1)
          if result >= 0 { connected.insert(address) }
        }
        let callback = state.withLock { state in
          for (name, address) in state.outputs where outputs[name] != address {
            state.drop(name)
          }
          let changed = state.inputs != inputs
          state.inputs = inputs
          state.outputs = outputs
          return changed ? state.onSourcesChange : nil
        }
        callback?(inputs.keys.sorted())
      }
      private func fail(_ message: String) {
        state.withLock {
          $0.error = message
          $0.running = false
        }
      }
      private func deliver(_ state: inout State, through time: UInt64) {
        let due = state.queue.takeDue(at: time)
        state.pending -= due.count
        for item in due {
          state.counts[item.destination, default: 0] -= 1
          if state.counts[item.destination] == 0 { state.counts.removeValue(forKey: item.destination) }
          let address =
            item.destination.isEmpty ? Address(client: -1, port: -1) : state.outputs[item.destination]
          guard let address else { continue }
          let result = item.message.withUnsafeBufferPointer {
            db_midi_send(handle, address.client, address.port, $0.baseAddress, Int32($0.count))
          }
          if result < 0 { state.error = "ALSA MIDI send failed (\(result))" }
        }
      }
      func run() {
        Thread.current.threadDictionary[workerKey] = true
        defer {
          let callback = state.withLock { state in
            state.running = false
            if let stopAt = state.stopAt { deliver(&state, through: stopAt) }
            state.inputs = [:]
            state.outputs = [:]
            state.queue = MIDIQueue()
            state.pending = 0
            state.counts = [:]
            db_midi_close(handle)
            return state.onSourcesChange
          }
          callback?([])
          finished.leave()
        }
        var refreshAt = HostTime.now()
        while state.withLock({ $0.running }) {
          let now = HostTime.now()
          if now >= refreshAt {
            refresh()
            refreshAt = HostTime.time(now, after: 0.25)
          }
          var inputPending = false
          for _ in 0..<256 {
            var client: Int32 = 0
            var port: Int32 = 0
            var length: Int32 = 0
            var bytes = [UInt8](repeating: 0, count: 3)
            let result = db_midi_receive(handle, &client, &port, &bytes, &length)
            inputPending = result != 0
            if result == 0 { break }
            if result < 0 {
              // ALSA reports an overrun once; later messages can still be received.
              if result != -ENOSPC {
                fail("ALSA MIDI input failed (\(result))")
              } else {
                sourceNames.removeAll()
                refreshAt = 0
              }
              break
            }
            if result == 2 {
              if client >= 0 {
                // A port can disappear and return at the same address between snapshots.
                // Exit announcements invalidate its queued output and subscription first.
                let removed = state.withLock { state -> Set<Address> in
                  let matches: (Address) -> Bool = { $0.client == client && (port < 0 || $0.port == port) }
                  let removed = Set(state.inputs.values.filter(matches))
                  for name in Array(state.outputs.keys) where state.outputs[name].map(matches) == true {
                    state.drop(name)
                    state.outputs.removeValue(forKey: name)
                  }
                  return removed
                }
                connected.subtract(removed)
                sourceNames = sourceNames.filter {
                  $0.key.client != client || (port >= 0 && $0.key.port != port)
                }
              }
              refreshAt = 0
              // Rebuild names before accepting bytes from a newly created or reused address.
              break
            }
            guard length > 0 else { continue }
            let time = HostTime.milliseconds()
            let source = sourceNames[Address(client: client, port: port)]
            let callbacks = state.withLock {
              state -> (
                (@Sendable (Int, Double) -> Void)?, (@Sendable ([UInt8]) -> Void)?,
                (@Sendable (ClockMessage, Double) -> Void)?
              ) in
              guard state.running, let source,
                !state.ignoring.contains(source)
              else { return (nil, nil, nil) }
              return (state.onNote, state.onMessage, state.onClock)
            }
            if bytes[0] < 0xF0 { callbacks.1?(bytes) }
            guard state.withLock({ $0.running }) else { break }
            switch MIDIMessage(status: bytes[0], bytes[1], bytes[2]) {
            case .note(let note, let velocity): callbacks.0?(note, velocity)
            case .clock(let clock): callbacks.2?(clock, time)
            case nil: break
            }
          }
          let next = state.withLock { state -> UInt64? in
            guard state.running else { return nil }
            deliver(&state, through: HostTime.now())
            return state.queue.next
          }
          if !state.withLock({ $0.running }) { break }
          let deadline = inputPending ? HostTime.now() : min(next ?? refreshAt, refreshAt)
          let delay = max(0, HostTime.seconds(from: HostTime.now(), to: deadline))
          if db_midi_wait(handle, Int64(min(delay, 0.25) * 1e9)) < 0 {
            fail("ALSA MIDI poll failed")
          }
        }
      }
    }
  }
#endif
