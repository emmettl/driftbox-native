#if canImport(CoreMIDI)
  import CoreMIDI
  import Foundation

  /// Bytes out, to one of the machine's destinations or to Driftbox's own virtual source — which
  /// is how another app on the same Mac is driven with nothing plugged in at all.
  ///
  /// Every message carries the host time it belongs to rather than going out the moment it is
  /// written. A clock driven from a thirty-a-second tick would otherwise arrive in bursts wearing
  /// all of the main thread's jitter, and a tempo read off ticks that arrive like that wanders.
  /// Handed to the MIDI server early with a timestamp, each message is played when it was stamped.
  public final class MIDIOutput: @unchecked Sendable {
    /// Where bytes go: one of the machine's destinations by name, or the port Driftbox publishes.
    public enum Destination: Hashable, Sendable {
      case virtual
      case port(String)
    }

    /// Every destination there is. Read again when the set of devices changes.
    public var destinations: [String] { lock.withLock { ports.map(\.name) } }

    private struct Port {
      var name: String
      var endpoint: MIDIEndpointRef
    }

    /// The endpoints are written from CoreMIDI's notification thread and read from whichever
    /// thread is sending, so they are never touched outside this.
    private let lock = NSLock()
    private var ports: [Port] = []
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var source = MIDIEndpointRef()

    public init() {
      var status = MIDIClientCreateWithBlock("Driftbox" as CFString, &client) { [weak self] _ in
        self?.refresh()
      }
      guard status == noErr else { return }
      status = MIDIOutputPortCreate(client, "Out" as CFString, &port)
      guard status == noErr else { return }
      // A source of our own as well as the ports that are there: a DAW or a sequencer on this
      // machine can be given the clock without a cable and without a loopback driver.
      MIDISourceCreateWithProtocol(client, "Driftbox Clock" as CFString, ._1_0, &source)
      refresh()
    }

    deinit {
      if source != 0 { MIDIEndpointDispose(source) }
      MIDIPortDispose(port)
      MIDIClientDispose(client)
    }

    /// Every destination, by name, in the order CoreMIDI has them.
    private func refresh() {
      var found: [Port] = []
      for index in 0..<MIDIGetNumberOfDestinations() {
        let endpoint = MIDIGetDestination(index)
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
        found.append(
          Port(name: name?.takeRetainedValue() as String? ?? "MIDI \(index)", endpoint: endpoint))
      }
      lock.withLock { ports = found }
    }

    /// Hand one MIDI 1.0 message to `destination`, to be played at `hostTime`. False when it went
    /// nowhere, which is what a destination that has been unplugged since it was chosen looks like
    /// from here. Safe to call from the main thread: neither the lookup nor the send waits on
    /// anything, and the lock is only ever held for a copy of the endpoint table.
    @discardableResult
    public func send(_ bytes: [UInt8], to destination: Destination, at hostTime: UInt64) -> Bool {
      guard let words = Self.words(for: bytes) else { return false }
      var list = MIDIEventList()
      return withUnsafeMutablePointer(to: &list) { list in
        let packet = MIDIEventListInit(list, ._1_0)
        return words.withUnsafeBufferPointer { words in
          guard let first = words.baseAddress else { return false }
          // A single word into a list that was just emptied has nowhere to fail.
          _ = MIDIEventListAdd(list, MemoryLayout<MIDIEventList>.size, packet, hostTime, words.count, first)
          switch destination {
          case .virtual:
            return source != 0 && MIDIReceivedEventList(source, list) == noErr
          case .port(let name):
            guard let endpoint = endpoint(named: name) else { return false }
            return MIDISendEventList(port, endpoint, list) == noErr
          }
        }
      }
    }

    /// Drop whatever is still queued for `destination`. A stop sent while a fifth of a second of
    /// ticks is still waiting would arrive before them, and the ticks behind it would leave the
    /// thing that was told to stop running on. Nothing can be taken back from the virtual source:
    /// what is sent there has already been handed to whoever is listening, and the scheduling is
    /// theirs from then on.
    public func flush(_ destination: Destination) {
      guard case .port(let name) = destination, let endpoint = endpoint(named: name) else { return }
      MIDIFlushOutput(endpoint)
    }

    private func endpoint(named name: String) -> MIDIEndpointRef? {
      lock.withLock { ports.first { $0.name == name }?.endpoint }
    }

    /// One MIDI 1.0 message as a Universal MIDI Packet on group zero, which is the protocol the
    /// port speaks. Nil for anything that does not fit in a single packet, system exclusive above
    /// all — the clock has no use for it and a half-written stream is worse than none.
    static func words(for bytes: [UInt8]) -> [UInt32]? {
      guard let status = bytes.first, status >= 0x80, status != 0xF0, status != 0xF7 else { return nil }
      let data1 = UInt32(bytes.count > 1 ? bytes[1] & 0x7F : 0)
      let data2 = UInt32(bytes.count > 2 ? bytes[2] & 0x7F : 0)
      // System common and real time are message type 1; everything with a channel in it is type 2.
      let type: UInt32 = status >= 0xF0 ? 1 : 2
      return [(type << 28) | (UInt32(status) << 16) | (data1 << 8) | data2]
    }

    // MARK: - The host clock

    /// Now, on the clock CoreMIDI stamps against.
    public static func now() -> UInt64 { mach_absolute_time() }

    /// `seconds` after `base`, which is not nanoseconds: the host clock ticks at whatever rate the
    /// machine says it does, and on Apple silicon that is twenty-four million a second.
    public static func time(_ base: UInt64, after seconds: Double) -> UInt64 {
      guard seconds.isFinite else { return base }
      let ticks = (seconds * ticksPerSecond).rounded()
      if ticks >= 0 { return base &+ UInt64(min(ticks, 1e18)) }
      let back = UInt64(min(-ticks, 1e18))
      return back < base ? base - back : 0
    }

    /// How long it is from `base` to `time`, negative when `time` has been and gone.
    public static func seconds(from base: UInt64, to time: UInt64) -> Double {
      let ahead = time >= base
      let difference = Double(ahead ? time - base : base - time) / ticksPerSecond
      return ahead ? difference : -difference
    }

    private static let ticksPerSecond: Double = {
      var info = mach_timebase_info_data_t()
      guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else { return 1e9 }
      return 1e9 * Double(info.denom) / Double(info.numer)
    }()
  }
#endif
