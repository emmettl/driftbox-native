import DriftboxRack
import Testing

/// A rack document carrying a groovebox song, classified as the reference's `groovebox.test.ts`
/// classifies it: what saving it keeps.
struct RetainedTests {
  static let song = "{\"v\":1}"

  @Test func aSongWithItsSourceAloneIsGrooveboxCompatible() {
    let patch = Patch.embedding(song: Self.song)
    #expect(patch.modules.map(\.type) == ["groovebox"])
    #expect(patch.groovebox == Self.song)
    #expect(patch.compatibility == .grooveboxCompatible)
    // An old bridge document with no source at all is the song alone too.
    var bare = Patch(modules: [], cables: [])
    bare.groovebox = Self.song
    #expect(bare.compatibility == .grooveboxCompatible)
  }

  @Test func aPatchWithoutASongIsRackNative() {
    #expect(Patch(modules: [], cables: []).compatibility == .rackNative)
    #expect(
      Patch(modules: [PatchModule(id: "groovebox", type: "groovebox")], cables: []).compatibility
        == .rackNative)
  }

  @Test func aSecondOrConfiguredSourceIsRackWork() {
    var two = Patch.embedding(song: Self.song)
    two.modules.append(PatchModule(id: "groovebox-2", type: "groovebox"))
    #expect(two.compatibility == .rackExtended)
    var turned = Patch.embedding(song: Self.song)
    turned.modules[0].params["tr808-level"] = 0.5
    #expect(turned.compatibility == .rackExtended)
  }

  @Test(arguments: [
    "module", "cable", "modulation", "voice count", "generated break", "tempo override", "visual",
  ])
  func anyRackAdditionExtendsIt(field: String) {
    var patch = Patch.embedding(song: Self.song)
    switch field {
    case "module": patch.modules = [PatchModule(id: "osc", type: "vco")]
    case "cable":
      patch.modules = [PatchModule(id: "osc", type: "vco"), PatchModule(id: "out", type: "out")]
      patch.cables = [PatchCable(from: PortReference("osc", "out"), to: PortReference("out", "in"))]
    case "modulation":
      patch.modules = [PatchModule(id: "combi", type: "combi"), PatchModule(id: "osc", type: "vco")]
      patch.modulation = [ModRoute(from: PortReference("combi", "rotary1"), to: PortReference("osc", "tune"))]
    case "voice count": patch.voices = 4
    case "generated break": patch.breakId = "amenish"
    case "tempo override": patch.tempo = 130
    default: patch.visual = "longhand"
    }
    #expect(patch.compatibility == .rackExtended, "\(field)")
    #expect(patch.groovebox == Self.song, "the song is kept whatever the rack adds")
  }

  @Test func aSingleVoiceIsTheDefault() {
    var patch = Patch.embedding(song: Self.song)
    patch.voices = 1
    #expect(patch.compatibility == .grooveboxCompatible)
  }
}
