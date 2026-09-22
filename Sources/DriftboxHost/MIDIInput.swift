#if canImport(CoreMIDI)
  import CoreMIDI
  import DriftboxSeq
  import Foundation

  /// Everything on every MIDI source, as it arrives. Notes go to `onNote` (note number, velocity
  /// 0...1 — 0 is a release); clock messages, stamped in milliseconds, to `onClock`. Both are
  /// called on CoreMIDI's own thread.
  public final class MIDIInput: @unchecked Sendable {
    public var onNote: (@Sendable (Int, Double) -> Void)?
    public var onClock: (@Sendable (ClockMessage, Double) -> Void)?
    public private(set) var sources: [String] = []

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()

    public init() {
      let name = "Driftbox" as CFString
      var status = MIDIClientCreateWithBlock(name, &client) { [weak self] _ in self?.connectAll() }
      guard status == noErr else { return }
      status = MIDIInputPortCreateWithProtocol(client, "In" as CFString, ._1_0, &port) {
        [weak self] list, _ in
        self?.receive(list)
      }
      guard status == noErr else { return }
      connectAll()
    }

    deinit {
      MIDIPortDispose(port)
      MIDIClientDispose(client)
    }

    /// Every source there is. Called again when the set of devices changes.
    private func connectAll() {
      var names: [String] = []
      for index in 0..<MIDIGetNumberOfSources() {
        let source = MIDIGetSource(index)
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name)
        names.append(name?.takeRetainedValue() as String? ?? "MIDI \(index)")
        MIDIPortConnectSource(port, source, nil)
      }
      sources = names
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>) {
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
