#if os(Android)
  import CAMidi
  import DriftboxHost
  import Synchronization

  /// Bytes out to the devices handed to `AMidiDevices`, each at the moment it is stamped with:
  /// Android's `MIDIOutputPort`.
  ///
  /// Android's MIDI takes a timestamp with every message, as CoreMIDI does, on the monotonic clock
  /// `HostTime` counts in, but it is the device's side that decides what the stamp means. Android's
  /// USB driver holds a message until then, by its source. A device that is another app is handed
  /// the message at once, stamp and all: measured against the app's own loopback, a clock sent a
  /// tenth of a second ahead arrived a tenth of a second early, and a flush dropped nothing. So
  /// until something here holds messages to their time, as WinMM's scheduler does on Windows, a
  /// clock is only on time at a device that keeps to its stamps.
  ///
  /// There is no virtual destination. An app can publish a MIDI device of its own on Android, but
  /// only as a Java service, which is the app's to add.
  public final class AMidiOutput: MIDIOutputPort, @unchecked Sendable {
    private struct Port {
      let device: Int32
      let name: String
      let handle: OpaquePointer
    }

    /// Opened, used and closed with this held, so a port is never closed mid-send.
    private let ports = Mutex<[Port]>([])
    private let devices: AMidiDevices

    public var destinations: [String] { ports.withLock { $0.map(\.name) } }
    public var offersVirtualSource: Bool { false }

    public init(devices: AMidiDevices) {
      self.devices = devices
      devices.watch(self) { [weak self] now in self?.devicesChanged(now) }
    }

    deinit {
      devices.unwatch(self)
      ports.withLock { ports in
        for port in ports { AMidiInputPort_close(port.handle) }
        ports = []
      }
    }

    @discardableResult
    public func send(_ bytes: [UInt8], to destination: MIDIDestination, at hostTime: UInt64) -> Bool {
      guard case .port(let name) = destination, !bytes.isEmpty else { return false }
      return ports.withLock { ports in
        guard let port = ports.first(where: { $0.name == name }) else { return false }
        let sent = bytes.withUnsafeBufferPointer {
          AMidiInputPort_sendWithTimestamp(
            port.handle, $0.baseAddress, $0.count, Int64(bitPattern: min(hostTime, UInt64(Int64.max))))
        }
        return sent >= 0
      }
    }

    public func flush(_ destination: MIDIDestination) {
      guard case .port(let name) = destination else { return }
      ports.withLock { ports in
        if let port = ports.first(where: { $0.name == name }) { _ = AMidiInputPort_sendFlush(port.handle) }
      }
    }

    /// Every destination of every device there now is, opened; those of devices gone, closed.
    private func devicesChanged(_ devices: [AMidiDevices.Device]) {
      ports.withLock { ports in
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
            ports.append(Port(device: device.id, name: name, handle: handle))
          }
        }
        let order = Dictionary(uniqueKeysWithValues: devices.enumerated().map { ($1.id, $0) })
        ports.sort { order[$0.device, default: 0] < order[$1.device, default: 0] }
      }
    }
  }
#endif
