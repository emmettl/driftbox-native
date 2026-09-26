import DriftboxRack
import Testing

@testable import DriftboxRackSession

/// The rack's own keys, on a patch with no MIDI module: they make one, as the reference's do, wired
/// to what can be played, rather than sounding nothing.
@MainActor
struct RackKeysBuildMIDITests {
  static func rack(_ modules: [PatchModule], _ cables: [PatchCable] = []) -> RackSession {
    let rack = RackSession()
    rack.open(Patch(modules: modules, cables: cables), name: "Keys")
    return rack
  }

  static func feeds(_ rack: RackSession, _ from: String, _ module: String, _ port: String) -> Bool {
    rack.patch.cables.contains {
      $0.from.module.hasPrefix("midi") && $0.from.port == from && $0.to.module == module && $0.to.port == port
    }
  }

  @Test func thePortsItWiresAreThere() {
    for (type, port) in [
      ("voice", "pitch"), ("voice", "gate"), ("multisampler", "velocity"), ("vco", "pitch"), ("adsr", "gate"),
      ("vca", "cv"),
    ] {
      #expect(RackModules.registry[type]?.inlets.contains { $0.id == port } == true, "\(type).\(port)")
    }
    #expect(RackModules.registry["midi"]?.outlets.map(\.id).starts(with: ["pitch", "gate", "vel"]) == true)
  }

  /// A Voice played by a Seq: the keys take its pitch and gate over, one step of undo gives them
  /// back, and a second note makes nothing more.
  @Test func theKeysTakeTheNewestVoice() throws {
    let rack = Self.rack(
      [
        PatchModule(id: "seq-1", type: "seq"), PatchModule(id: "voice-1", type: "voice"),
        PatchModule(id: "voice-2", type: "voice"), PatchModule(id: "out-1", type: "out"),
      ],
      [
        PatchCable(from: PortReference("seq-1", "pitch"), to: PortReference("voice-2", "pitch")),
        PatchCable(from: PortReference("seq-1", "gate"), to: PortReference("voice-2", "gate")),
        PatchCable(from: PortReference("voice-2", "out"), to: PortReference("out-1", "in")),
      ])
    rack.keyDown(60)
    rack.noteUp(60)
    #expect(Self.feeds(rack, "pitch", "voice-2", "pitch") && Self.feeds(rack, "gate", "voice-2", "gate"))
    #expect(!rack.patch.cables.contains { $0.from.module == "seq-1" }, "one cable an input")
    #expect(rack.patch.modules.filter { $0.type == "midi" }.count == 1)
    rack.keyDown(62)
    #expect(rack.patch.modules.filter { $0.type == "midi" }.count == 1, "made once")
    rack.undo()
    #expect(!rack.patch.modules.contains { $0.type == "midi" })
    #expect(rack.patch.cables.contains { $0.from.module == "seq-1" }, "the sequencer back")
  }

  /// With no instrument, a VCO's pitch, and its gate to an ADSR, or a VCA without one.
  @Test func orAVCOAndItsGate() {
    let enveloped = Self.rack([
      PatchModule(id: "vco-1", type: "vco"), PatchModule(id: "adsr-1", type: "adsr"),
      PatchModule(id: "vca-1", type: "vca"),
    ])
    enveloped.keyDown(60)
    #expect(
      Self.feeds(enveloped, "pitch", "vco-1", "pitch") && Self.feeds(enveloped, "gate", "adsr-1", "gate"))

    let plain = Self.rack([PatchModule(id: "vco-1", type: "vco"), PatchModule(id: "vca-1", type: "vca")])
    plain.keyDown(60)
    #expect(Self.feeds(plain, "gate", "vca-1", "cv"))
  }

  /// Nothing to play, or a MIDI module there already: the patch left as it is.
  @Test func otherwiseNothing() {
    let empty = Self.rack([PatchModule(id: "out-1", type: "out")])
    empty.keyDown(60)
    #expect(empty.patch.modules.count == 1 && !empty.canUndo)

    let keyed = Self.rack([PatchModule(id: "keys", type: "midi"), PatchModule(id: "voice-1", type: "voice")])
    keyed.keyDown(60)
    #expect(keyed.patch.cables.isEmpty && !keyed.canUndo, "a patch somebody built is not rearranged")
  }
}
