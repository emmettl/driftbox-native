import DriftboxHost
import DriftboxRack
import DriftboxRackSession
import DriftboxSeq
import DriftboxSession
import Testing

@testable import DriftboxTouch

/// A MIDI keyboard on a touch screen: the groovebox's, and the rack's while it shows.
@MainActor
struct TouchscreenMIDITests {
  /// A MIDI input with nothing behind it, played by the test.
  final class Keys: MIDIInputPort, @unchecked Sendable {
    var onNote: (@Sendable (Int, Double) -> Void)?
    var onMessage: (@Sendable ([UInt8]) -> Void)?
    var onClock: (@Sendable (ClockMessage, Double) -> Void)?
    var onSourcesChange: (@Sendable ([String]) -> Void)?
    var sources: [String] = ["Keystation"]
    var ignoring: Set<String> = []

    /// A note down or up, as a port delivers one: the message whole, then the note.
    func play(_ note: UInt8, velocity: UInt8) {
      onMessage?([velocity > 0 ? 0x90 : 0x80, note, velocity])
      onNote?(Int(note), Double(velocity) / 127)
    }
  }

  @Test func aKeyboardPlaysTheRackWhileItShows() throws {
    guard let device = try TouchscreenTests.device() else { return }
    let keys = Keys()
    let session = Session(host: EngineHost(sampleRate: 48000), midiIn: keys)
    let screen = try Touchscreen(session: session, device: device, typesetter: NoType(), scale: 3)
    let rack = RackSession()
    rack.open(
      Patch(
        modules: [PatchModule(id: "keys", type: "midi"), PatchModule(id: "out", type: "out")], cables: []),
      name: "Keys")
    screen.add(rack)
    #expect(rack.midiSources == ["Keystation"], "told the sources there are")

    keys.play(60, velocity: 100)
    #expect(rack.sounding.isEmpty, "the groovebox's while the rack is away")
    keys.play(60, velocity: 0)

    screen.show(rack: true)
    keys.play(60, velocity: 100)
    #expect(rack.sounding == [60], "the rack's while it shows")
    keys.play(60, velocity: 0)
    #expect(rack.sounding.isEmpty)

    screen.show(rack: false)
    keys.play(62, velocity: 100)
    #expect(rack.sounding.isEmpty, "and the groovebox's again once it has gone")

    keys.onSourcesChange?(["Keystation", "Launchkey"])
    #expect(rack.midiSources == ["Keystation", "Launchkey"], "and told as they change")
  }
}
