#if os(Android)
  import CAMidi
  import DriftboxHost
  import Synchronization

  /// Bytes out to the devices handed to `AMidiDevices`, each at the moment it is stamped with:
  /// Android's `MIDIOutputPort`.
  ///
  /// Android's MIDI takes a timestamp with every message, as CoreMIDI does, on the monotonic clock
  /// `HostTime` counts in, but it is the device's side that decides what the stamp means. Android's
  /// USB driver holds a message until then, by its source, so a USB device is sent everything at
  /// once. A device that is another app is handed a message the moment it is sent — measured
  /// against the app's own loopback, a clock sent a tenth of a second ahead arrived a tenth of a
  /// second early — so for it, and for anything else that is not USB, `MIDIScheduler` holds each
  /// message until it is due, as WinMM's does on Windows. Either way it goes with its stamp.
  ///
  /// A flush drops what the scheduler is holding, and asks the device to drop what it is.
  ///
  /// There is no virtual destination. An app can publish a MIDI device of its own on Android, but
  /// only as a Java service, which is the app's to add.
  public final class AMidiOutput: MIDIOutputPort, @unchecked Sendable {
    private let ports = Ports()
    private let devices: AMidiDevices
    private let scheduler: MIDIScheduler

    public var destinations: [String] { ports.list.withLock { $0.map(\.name) } }
    public var offersVirtualSource: Bool { false }

    /// Whether the scheduler's thread got the priority it asked for.
    public var scheduledUrgently: Bool { scheduler.urgent }

    /// How late the scheduler sent what it held since last asked, in milliseconds after the
    /// stamps: at least, on average and at most. Apart from anything after it.
    public func takeLateness() -> (count: Int, least: Double, average: Double, most: Double) {
      let lateness = scheduler.takeLateness()
      return (lateness.count, lateness.least, lateness.average, lateness.most)
    }

    public init(devices: AMidiDevices) {
      self.devices = devices
      scheduler = MIDIScheduler(
        cores: PerformanceCores.choose(maximumFrequencies: Bionic.maximumFrequencies())
      ) {
        [ports] name, bytes, stamp in _ = ports.send(bytes, to: name, stamped: stamp)
      }
      devices.watch(self) { [weak self] now in self?.devicesChanged(now) }
    }

    deinit {
      devices.unwatch(self)
      scheduler.stop()
      ports.list.withLock { ports in
        for port in ports { AMidiInputPort_close(port.handle) }
        ports = []
      }
    }

    @discardableResult
    public func send(_ bytes: [UInt8], to destination: MIDIDestination, at hostTime: UInt64) -> Bool {
      guard case .port(let name) = destination, !bytes.isEmpty else { return false }
      switch ports.held(name) {
      case nil: return false
      case true?:
        scheduler.schedule(bytes, to: name, at: hostTime)
        return true
      case false?:
        return ports.send(bytes, to: name, stamped: hostTime)
      }
    }

    public func flush(_ destination: MIDIDestination) {
      guard case .port(let name) = destination else { return }
      scheduler.drop(name)
      ports.list.withLock { ports in
        if let port = ports.first(where: { $0.name == name }) { _ = AMidiInputPort_sendFlush(port.handle) }
      }
    }

    /// Every destination of every device there now is, opened; those of devices gone, closed.
    private func devicesChanged(_ devices: [AMidiDevices.Device]) {
      ports.list.withLock { ports in
        let present = Set(devices.map(\.id))
        for port in ports where !present.contains(port.device) { AMidiInputPort_close(port.handle) }
        ports.removeAll { !present.contains($0.device) }
        let open = Set(ports.map(\.device))
        for device in devices where !open.contains(device.id) {
          let count = AMidiDevice_getNumInputPorts(device.handle)
          guard count > 0 else { continue }
          for number in 0..<Int(count) {
            var handle: OpaquePointer?
            guard AMidiInputPort_open(device.handle, Int32(number), &handle) == AMEDIA_OK, let handle
            else { continue }
            let name = MIDIPortNaming.port(number, of: Int(count), on: device.name)
            ports.append(Port(device: device.id, name: name, handle: handle, held: !device.usb))
          }
        }
        let order = Dictionary(uniqueKeysWithValues: devices.enumerated().map { ($1.id, $0) })
        ports.sort { order[$0.device, default: 0] < order[$1.device, default: 0] }
      }
    }

    private struct Port: @unchecked Sendable {
      let device: Int32
      let name: String
      let handle: OpaquePointer
      /// Whether messages for it wait in the scheduler until they are due.
      let held: Bool
    }

    /// The open ports, shared with the scheduler's thread, which sends through them too.
    private final class Ports: Sendable {
      /// Opened, used and closed with this held, so a port is never closed mid-send.
      let list = Mutex<[Port]>([])

      /// Whether the port called `name` has its messages held; nil if there is no such port.
      func held(_ name: String) -> Bool? {
        list.withLock { ports in ports.first { $0.name == name }?.held }
      }

      /// `bytes` to the port called `name` now, with `stamp`. False if it went nowhere.
      func send(_ bytes: [UInt8], to name: String, stamped stamp: UInt64) -> Bool {
        list.withLock { ports in
          guard let port = ports.first(where: { $0.name == name }) else { return false }
          let sent = bytes.withUnsafeBufferPointer {
            AMidiInputPort_sendWithTimestamp(
              port.handle, $0.baseAddress, $0.count, Int64(bitPattern: min(stamp, UInt64(Int64.max))))
          }
          return sent >= 0
        }
      }
    }
  }
#endif
