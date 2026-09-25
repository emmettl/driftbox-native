import DriftboxCanvas
import DriftboxInterface
import DriftboxRack
import DriftboxRackSession
import DriftboxShell
import Testing

/// The rack's keys on a touchscreen: shown when the patch has a MIDI module to play, a finger a
/// note, slid from key to key, struck harder lower down, moved by the octave, and put away.
@MainActor
struct RackKeysTests {
  static func rack(midi: Bool = true) -> RackInterface {
    let rack = RackSession()
    var modules = [PatchModule(id: "osc", type: "vco"), PatchModule(id: "out", type: "out")]
    if midi { modules.insert(PatchModule(id: "keys", type: "midi"), at: 0) }
    var patch = Patch(modules: modules, cables: [])
    // Voices for a chord.
    patch.voices = 4
    rack.open(patch, name: "Keys")
    let face = RackInterface(rack: rack)
    face.touch = true
    face.size = RackTouchTests.phone
    return face
  }

  static func key(_ face: RackInterface, _ note: Int) throws -> RackKeys.Key {
    try #require(face.stage.keyboard?.keys.first { $0.note == note })
  }

  static func centre(_ key: RackKeys.Key) -> SIMD2<Float> { RackInterfaceTests.centre(key.frame) }

  @Test func theKeysShowForAPatchWithAMIDIModule() throws {
    let face = Self.rack()
    let stage = face.stage
    let keys = try #require(stage.keyboard)
    #expect(stage.area.maxY <= keys.frame.y, "the rack above them")
    #expect(keys.keys.filter { !$0.black }.count == 7, "an octave, on a phone")
    #expect(keys.keys.filter(\.black).count == 5)
    #expect(keys.keys.filter { !$0.black }.allSatisfy { $0.frame.width >= 44 }, "a finger's width")
    #expect(stage.keysChip == nil)
    let bare = Self.rack(midi: false)
    #expect(bare.stage.keyboard == nil && bare.stage.keysChip != nil, "none to play, and a chip to show them")
    // A tablet, as many octaves as fit.
    face.size = SIMD2(1280, 800)
    #expect(try #require(face.stage.keyboard).keys.filter { !$0.black }.count > 8)
    // A desktop has its typing keys, and none of these.
    face.touch = false
    #expect(face.stage.keyboard == nil && face.stage.keysChip == nil)
  }

  @Test func aFingerPlaysAKeyAndSlidesToTheNext() throws {
    let face = Self.rack()
    let c = try Self.key(face, 0)
    let d = try Self.key(face, 2)
    RackTouchTests.finger(face, .began, 1, Self.centre(c))
    #expect(face.rack.sounding == [RackKeyboard.root])
    RackTouchTests.finger(face, .moved, 1, Self.centre(d))
    #expect(face.rack.sounding == [RackKeyboard.root + 2], "the one before let go")
    RackTouchTests.finger(face, .ended, 1, Self.centre(d))
    #expect(face.rack.sounding.isEmpty)
  }

  /// Two fingers on the keys are a chord, not a pinch.
  @Test func twoFingersAreAChord() throws {
    let face = Self.rack()
    let c = try Self.key(face, 0)
    let e = try Self.key(face, 4)
    RackTouchTests.finger(face, .began, 1, Self.centre(c))
    RackTouchTests.finger(face, .began, 2, Self.centre(e))
    #expect(Set(face.rack.sounding) == [RackKeyboard.root, RackKeyboard.root + 4])
    RackTouchTests.finger(face, .moved, 2, Self.centre(e) + SIMD2(0, 20))
    #expect(face.zoom == 1)
    RackTouchTests.finger(face, .ended, 1, Self.centre(c))
    RackTouchTests.finger(face, .ended, 2, Self.centre(e))
    #expect(face.rack.sounding.isEmpty)
  }

  /// Lower down a key, harder.
  @Test func lowerIsHarder() throws {
    let keys = try #require(Self.rack().stage.keyboard)
    let c = try #require(keys.keys.first { $0.note == 0 })
    let top = try #require(keys.key(at: SIMD2(c.frame.x + 4, c.frame.y + 2)))
    let foot = try #require(keys.key(at: SIMD2(c.frame.x + 4, c.frame.maxY - 2)))
    #expect(top.key.note == 0 && foot.key.note == 0)
    #expect(top.velocity < 0.5 && foot.velocity > 0.95)
    // A black key sits over the white.
    let black = try #require(keys.keys.first { $0.note == 1 })
    #expect(keys.key(at: RackInterfaceTests.centre(black.frame))?.key.note == 1)
  }

  @Test func theOctaveMovesAndTheKeysPutAway() throws {
    let face = Self.rack()
    let keys = try #require(face.stage.keyboard)
    RackTouchTests.tap(face, RackInterfaceTests.centre(keys.up))
    #expect(face.octave == 1)
    let c = try Self.key(face, 0)
    RackTouchTests.finger(face, .began, 1, Self.centre(c))
    #expect(face.rack.sounding == [RackKeyboard.root + 12])
    // Put away with a key down: it is let go of.
    RackTouchTests.tap(face, RackInterfaceTests.centre(keys.hide), id: 2)
    #expect(face.stage.keyboard == nil && face.rack.sounding.isEmpty)
    let chip = try #require(face.stage.keysChip)
    RackTouchTests.tap(face, RackInterfaceTests.centre(chip.frame))
    #expect(face.stage.keyboard != nil)
  }
}
