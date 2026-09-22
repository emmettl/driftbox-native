#if canImport(CoreMIDI)
  import CoreMIDI
  import DriftboxSeq
  import Foundation
  import Synchronization

  /// Every MIDI source, as it arrives, less any it has been told to ignore. Notes go to `onNote`
  /// (note number, velocity 0...1 — 0 is a release); clock messages, stamped in milliseconds, to
  /// `onClock`; the list of sources, whenever a device comes or goes, to `onSourcesChange`. All
  /// three are called on CoreMIDI's own thread.
  ///
  /// Everything here is read on that thread and written on another, so all of it sits behind
  /// one lock — the callbacks too, since a message can arrive between making this and setting
  /// them.
  public final class MIDIInput: Sendable {
    private struct State {
      /// Each connected source's name, by the endpoint its messages are tagged with.
      var names: [MIDIEndpointRef: String] = [:]
      /// The same names in the order CoreMIDI lists them, which is the order a person sees.
      var ordered: [String] = []
      var ignoring: Set<String> = []
      var hiding: Set<MIDIUniqueID> = []
      var onNote: (@Sendable (Int, Double) -> Void)?
      var onClock: (@Sendable (ClockMessage, Double) -> Void)?
      var onSourcesChange: (@Sendable ([String]) -> Void)?
    }

    private let state = Mutex(State())
    private let client: MIDIClientRef
    private let port: MIDIPortRef

    public var onNote: (@Sendable (Int, Double) -> Void)? {
      get { state.withLock { $0.onNote } }
      set { state.withLock { $0.onNote = newValue } }
    }

    public var onClock: (@Sendable (ClockMessage, Double) -> Void)? {
      get { state.withLock { $0.onClock } }
      set { state.withLock { $0.onClock = newValue } }
    }

    public var onSourcesChange: (@Sendable ([String]) -> Void)? {
      get { state.withLock { $0.onSourcesChange } }
      set { state.withLock { $0.onSourcesChange = newValue } }
    }

    /// Every source there is, whether it is being listened to or not.
    public var sources: [String] { state.withLock { $0.ordered } }

    /// Sources to hear nothing from, by name. By name rather than by endpoint because a
    /// device unplugged and plugged back in comes back as a new endpoint with the same name,
    /// and what someone chose to ignore was the device.
    public var ignoring: Set<String> {
      get { state.withLock { $0.ignoring } }
      set { state.withLock { $0.ignoring = newValue } }
    }

    /// Sources that are not there at all, as far as this input is concerned: never connected,
    /// never listed. For the app's own output, which is not a thing anybody wants to listen to
    /// and, listened to, is a loop.
    public var hiding: Set<MIDIUniqueID> {
      get { state.withLock { $0.hiding } }
      set {
        state.withLock { $0.hiding = newValue }
        connectAll()
      }
    }

    public init() {
      // The client and port are made before `self` is whole, so the blocks that need it find
      // it through a box filled in afterwards rather than capturing it half-built.
      let box = Box()
      var client = MIDIClientRef()
      var port = MIDIPortRef()
      // The client on the MIDI thread, so devices coming and going are heard whoever made this —
      // see `MIDIRunLoop`. Messages themselves arrive on CoreMIDI's own thread either way.
      let status = MIDIRunLoop.shared.sync {
        MIDIClientCreateWithBlock("Driftbox" as CFString, &client) { _ in box.input?.connectAll() }
      }
      if status == noErr {
        MIDIInputPortCreateWithProtocol(client, "In" as CFString, ._1_0, &port) { list, tag in
          box.input?.receive(list, from: MIDIEndpointRef(UInt(bitPattern: tag)))
        }
      }
      self.client = client
      self.port = port
      box.input = self
      connectAll()
    }

    deinit {
      MIDIPortDispose(port)
      MIDIClientDispose(client)
    }

    private final class Box: @unchecked Sendable {
      weak var input: MIDIInput?
    }

    /// Every source there is, each tagged with its own endpoint so a message can say where it
    /// came from. Called again whenever the set of devices changes.
    private func connectAll() {
      guard port != 0 else { return }
      let hiding = state.withLock { $0.hiding }
      var names: [MIDIEndpointRef: String] = [:]
      var ordered: [String] = []
      for index in 0..<MIDIGetNumberOfSources() {
        let source = MIDIGetSource(index)
        var id: MIDIUniqueID = 0
        if MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &id) == noErr, hiding.contains(id) {
          MIDIPortDisconnectSource(port, source)
          continue
        }
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name)
        let shown = name?.takeRetainedValue() as String? ?? "MIDI \(index)"
        names[source] = shown
        ordered.append(shown)
        MIDIPortConnectSource(port, source, UnsafeMutableRawPointer(bitPattern: UInt(source)))
      }
      let announce = state.withLock { state in
        state.names = names
        state.ordered = ordered
        return state.onSourcesChange
      }
      announce?(ordered)
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>, from source: MIDIEndpointRef) {
      let (onNote, onClock) = state.withLock { state in
        // A source not in the table yet was connected a moment ago; it is heard, as every
        // source is until somebody says otherwise.
        if let name = state.names[source], state.ignoring.contains(name) {
          return ((@Sendable (Int, Double) -> Void)?.none, (@Sendable (ClockMessage, Double) -> Void)?.none)
        }
        return (state.onNote, state.onClock)
      }
      guard onNote != nil || onClock != nil else { return }
      let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
      for packet in list.unsafeSequence() {
        // Universal MIDI Packets, protocol 1.0: each word is one message.
        for word in packet.words() {
          let type = (word >> 28) & 0xF
          let status = UInt8((word >> 16) & 0xFF)
          let data1 = UInt8((word >> 8) & 0x7F)
          let data2 = UInt8(word & 0x7F)
          switch type {
          case 1:
            if let message = ClockMessage(bytes: [status, data1, data2]) { onClock?(message, now) }
          case 2:
            switch status & 0xF0 {
            case 0x90: onNote?(Int(data1), Double(data2) / 127)
            case 0x80: onNote?(Int(data1), 0)
            default: break
            }
          default:
            break
          }
        }
      }
    }
  }
#endif
