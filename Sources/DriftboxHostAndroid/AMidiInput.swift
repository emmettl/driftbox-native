#if os(Android)
  import Android
  import CAMidi
  import DriftboxHost
  import DriftboxSeq
  import Synchronization

  /// Every MIDI source among the devices handed to `AMidiDevices`, as it arrives, less any it has
  /// been told to ignore: Android's `MIDIInputPort`.
  ///
  /// Android's native MIDI has no callback for arriving bytes; a port is asked whether it has any.
  /// So a thread of its own asks every open port in turn, a millisecond apart when nothing came,
  /// and frames what it gets with a `MIDIByteStream` per port. The callbacks are called on that
  /// thread. A clock message is stamped with when Android says it arrived, which is on the same
  /// clock as `HostTime` there, so the millisecond of asking does not reach the tempo.
  public final class AMidiInput: MIDIInputPort, @unchecked Sendable {
    private let core: Core
    private let devices: AMidiDevices
    private var thread = pthread_t()

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

    public var sources: [String] { core.state.withLock { $0.ordered } }

    public var ignoring: Set<String> {
      get { core.state.withLock { $0.ignoring } }
      set { core.state.withLock { $0.ignoring = newValue } }
    }

    public init(devices: AMidiDevices) {
      self.devices = devices
      core = Core()
      devices.watch(core) { [core] now in core.devicesChanged(now) }
      pthread_create(
        &thread, nil,
        { context in
          guard let context else { return nil }
          Unmanaged<Core>.fromOpaque(context).takeRetainedValue().run()
          return nil
        }, Unmanaged.passRetained(core).toOpaque())
    }

    deinit {
      devices.unwatch(core)
      core.running.store(false, ordering: .releasing)
      pthread_join(thread, nil)
      core.closeAll()
    }

    /// What the reading thread and the rest share. The thread holds this and nothing else, so
    /// letting go of the input is what ends it.
    private final class Core: @unchecked Sendable {
      struct State {
        var ordered: [String] = []
        var ignoring: Set<String> = []
        var onNote: (@Sendable (Int, Double) -> Void)?
        var onMessage: (@Sendable ([UInt8]) -> Void)?
        var onClock: (@Sendable (ClockMessage, Double) -> Void)?
        var onSourcesChange: (@Sendable ([String]) -> Void)?
      }

      /// One open source. Unchecked because its stream is only touched with `ports` held.
      final class Port: @unchecked Sendable {
        let device: Int32
        let name: String
        let handle: OpaquePointer
        var stream = MIDIByteStream()
        init(device: Int32, name: String, handle: OpaquePointer) {
          self.device = device
          self.name = name
          self.handle = handle
        }
      }

      struct Arrival {
        var source: String
        var bytes: [UInt8]
        var nanoseconds: Int64
      }

      let state = Mutex(State())
      /// Opened and closed with this held, and read with it held, so a port is never closed while
      /// it is being read.
      let ports = Mutex<[Port]>([])
      let running = Atomic<Bool>(true)

      func run() {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buffer.deallocate() }
        while running.load(ordering: .acquiring) {
          var arrived: [Arrival] = []
          ports.withLock { ports in
            for port in ports {
              var opcode: Int32 = 0
              var count = 0
              var stamp: Int64 = 0
              while AMidiOutputPort_receive(port.handle, &opcode, buffer, 1024, &count, &stamp) > 0 {
                guard opcode == AMIDI_OPCODE_DATA else { continue }
                let source = port.name
                port.stream.feed(UnsafeBufferPointer(start: buffer, count: count)) {
                  arrived.append(Arrival(source: source, bytes: $0, nanoseconds: stamp))
                }
              }
            }
          }
          if arrived.isEmpty {
            var interval = timespec(tv_sec: 0, tv_nsec: 1_000_000)
            nanosleep(&interval, nil)
          }
          for arrival in arrived { deliver(arrival) }
        }
      }

      private func deliver(_ arrival: Arrival) {
        let (onNote, onMessage, onClock) = state.withLock { state in
          state.ignoring.contains(arrival.source)
            ? (nil, nil, nil) : (state.onNote, state.onMessage, state.onClock)
        }
        let bytes = arrival.bytes
        guard let status = bytes.first else { return }
        // A channel message whole, as the Mac passes it on, before what Driftbox makes of it.
        if (0x80..<0xF0).contains(status) { onMessage?(bytes) }
        let data1 = bytes.count > 1 ? bytes[1] : 0
        let data2 = bytes.count > 2 ? bytes[2] : 0
        switch MIDIMessage(status: status, data1, data2) {
        case .note(let note, let velocity): onNote?(note, velocity)
        case .clock(let clock):
          let milliseconds =
            arrival.nanoseconds > 0 ? Double(arrival.nanoseconds) / 1_000_000 : HostTime.milliseconds()
          onClock?(clock, milliseconds)
        case nil: break
        }
      }

      /// Every source of every device there now is, opened; those of devices gone, closed.
      func devicesChanged(_ devices: [AMidiDevices.Device]) {
        let names = ports.withLock { ports in
          let present = Set(devices.map(\.id))
          for port in ports where !present.contains(port.device) { AMidiOutputPort_close(port.handle) }
          ports.removeAll { !present.contains($0.device) }
          let open = Set(ports.map(\.device))
          for device in devices where !open.contains(device.id) {
            let count = AMidiDevice_getNumOutputPorts(device.handle)
            guard count > 0 else { continue }
            for number in 0..<Int(count) {
              var handle: OpaquePointer?
              guard AMidiOutputPort_open(device.handle, Int32(number), &handle) == AMEDIA_OK, let handle
              else { continue }
              let name = MIDIPortNaming.port(number, of: Int(count), on: device.name)
              ports.append(Port(device: device.id, name: name, handle: handle))
            }
          }
          // In the order the devices arrived, so the list does not shuffle as one comes and goes.
          let order = Dictionary(uniqueKeysWithValues: devices.enumerated().map { ($1.id, $0) })
          ports.sort { order[$0.device, default: 0] < order[$1.device, default: 0] }
          return ports.map(\.name)
        }
        let announce = state.withLock { state in
          state.ordered = names
          return state.onSourcesChange
        }
        announce?(names)
      }

      func closeAll() {
        ports.withLock { ports in
          for port in ports { AMidiOutputPort_close(port.handle) }
          ports = []
        }
      }
    }
  }
#endif
