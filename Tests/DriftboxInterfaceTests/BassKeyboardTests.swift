import DriftboxEngine
import DriftboxInterface
import DriftboxSeq
import DriftboxSession
import DriftboxShell
import Testing

/// On a phone a 303 step's note is set as the machine's own are: the step chosen, then a key, and on
/// to the next. The keyboard stays clear of the grid it is setting.
@MainActor
struct BassKeyboardTests {
  /// The interface tests' song with 303 A in it: C1 on the first step, paused on the second.
  static func phone() throws -> Interface {
    var song = InterfaceTests.song()
    var steps = Array(repeating: BassStep(), count: 16)
    steps[0] = BassStep(note: 0)
    steps[1] = BassStep(note: 3, gate: false)
    song.patterns[0].bass["303.a"] = steps
    let interface = try InterfaceTests.interface(song)
    interface.size = SIMD2(372, 828)
    return interface
  }

  static func tap(_ interface: Interface, _ rect: Rect) {
    let at = InterfaceTests.centre(rect)
    interface.pointer(PointerEvent(phase: .began, id: 3, kind: .touch, location: at))
    interface.pointer(PointerEvent(phase: .ended, id: 3, kind: .touch, location: at))
  }

  static func bass(_ interface: Interface, _ index: Int) -> BassStep? {
    interface.session.song?.patterns[0].bassStep("303.a", at: index)
  }

  /// A 303 step on the grid, and the keyboard for it: over the scene, clear of the grid.
  static func open(_ interface: Interface, step index: Int) throws -> BassKeyboard {
    let layout = interface.layout
    let line = try #require(layout.bassLines.first)
    let metrics = try #require(layout.metrics)
    let cell = Rect(
      line.cells.x + Float(index - metrics.first) * metrics.stride, line.cells.y, metrics.cell,
      line.cells.height)
    tap(interface, cell)
    return try #require(interface.keyboard)
  }

  @Test func aStepTappedOpensItsKeyboard() throws {
    let interface = try Self.phone()
    let keyboard = try Self.open(interface, step: 0)
    #expect(interface.bassSelection?.voice == "303.a" && interface.bassSelection?.index == 0)
    let grid = try #require(interface.layout.grid)
    #expect(keyboard.frame.maxY <= grid.y, "above the grid, clear of it: \(keyboard.frame), \(grid)")
    #expect(keyboard.keys.count == 13, "an octave and the C above")
    #expect(keyboard.keys.filter { !$0.black }.allSatisfy { $0.frame.width >= 38 }, "each a finger wide")
  }

  /// With every drum in the pattern the grid would fill the phone; open, the keyboard makes it
  /// shorter rather than covering it, and scrolls the 303 line into sight.
  @Test func aTallGridMakesRoomForTheKeyboard() throws {
    var song = InterfaceTests.song()
    for voice in allVoices { song.patterns[0].tracks[voice.id] = Array(repeating: .off, count: 16) }
    song.patterns[0].bass["303.a"] = Array(repeating: BassStep(note: 0), count: 16)
    let interface = try InterfaceTests.interface(song)
    interface.size = SIMD2(372, 828)
    // Below the bottom of the phone until it is scrolled to: chosen as a tap on it would.
    interface.perform(.bassStep(voice: "303.a", index: 2))
    let keyboard = try #require(interface.keyboard)
    let layout = interface.layout
    let grid = try #require(layout.grid)
    let strip = try #require(layout.strip)
    #expect(keyboard.frame.y >= strip.maxY && keyboard.frame.maxY <= grid.y, "between the strip and the grid")
    let line = try #require(layout.bassLines.first)
    let rows = try #require(layout.gridContent)
    #expect(
      line.cells.y >= rows.y && line.cells.maxY <= rows.maxY, "the 303 line in sight: \(line.cells), \(rows)")
  }

  @Test func aKeySetsTheNoteAndMovesOn() throws {
    let interface = try Self.phone()
    let keyboard = try Self.open(interface, step: 0)
    let g = try #require(keyboard.keys.first { $0.note == 7 })
    Self.tap(interface, g.frame)
    #expect(Self.bass(interface, 0)?.note == 7, "G1 on the first step")
    #expect(Self.bass(interface, 0)?.sounds == true)
    #expect(interface.bassSelection?.index == 1, "and on to the second")
    let next = try #require(interface.keyboard)
    let fSharp = try #require(next.keys.first { $0.note == 6 && $0.black })
    Self.tap(interface, fSharp.frame)
    #expect(
      Self.bass(interface, 1)?.note == 6 && Self.bass(interface, 1)?.sounds == true, "a black key, sounding")
  }

  @Test func theChipsSetTheRestOfAStep() throws {
    let interface = try Self.phone()
    var keyboard = try Self.open(interface, step: 0)
    func chip(_ label: String) throws -> Rect {
      try #require(keyboard.chips.first { $0.label.hasPrefix(label) }).frame
    }
    Self.tap(interface, try chip("ACCENT"))
    Self.tap(interface, try chip("SLIDE"))
    Self.tap(interface, try chip("REST"))
    let step = try #require(Self.bass(interface, 0))
    #expect(
      step.accent && step.slide && !step.sounds && step.note == 0, "accented, sliding, resting, still C1")
    keyboard = try #require(interface.keyboard)
    Self.tap(interface, try chip("C1–C2"))
    #expect(interface.keyboard?.keys.first?.note == 12, "an octave up")
    keyboard = try #require(interface.keyboard)
    Self.tap(interface, try chip("◀"))
    #expect(interface.bassSelection?.index == 15, "back round to the last step")
    #expect(interface.page == 1, "on its page")
    keyboard = try #require(interface.keyboard)
    Self.tap(interface, try chip("×"))
    #expect(interface.keyboard == nil, "and put away")
  }

  /// The keyboard and a voice's knobs want the same room on a phone, so either puts the other away.
  @Test func theKeyboardAndTheKnobsTakeTurns() throws {
    let interface = try Self.phone()
    _ = try Self.open(interface, step: 0)
    interface.perform(.select(voice: "909.bd"))
    #expect(interface.keyboard == nil && interface.layout.inspector != nil, "the knobs, and no keyboard")
    interface.perform(.bassStep(voice: "303.a", index: 3))
    #expect(interface.keyboard != nil && interface.layout.inspector == nil, "the keyboard, and no knobs")
  }

  @Test func aDesktopHasNoKeyboard() throws {
    var song = InterfaceTests.song()
    song.patterns[0].bass["303.a"] = Array(repeating: BassStep(), count: 16)
    let interface = try InterfaceTests.interface(song)
    let line = try #require(interface.layout.bassLines.first)
    #expect(
      interface.layout.action(at: SIMD2(line.cells.x + 2, line.cells.y + 2))
        == .note(pattern: "p", voice: "303.a", index: 0, note: 24), "the piano roll's top note, as before")
    #expect(interface.keyboard == nil)
  }
}
