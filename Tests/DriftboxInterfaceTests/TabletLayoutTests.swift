import DriftboxEngine
import DriftboxInterface
import DriftboxSeq
import DriftboxSession
import DriftboxShell
import Testing

/// The controls on a tablet: a roomier phone's. The steps at a finger's size, beside their names
/// rather than under them, all sixteen where they fit and a page of eight where they do not; the
/// 303's notes set on a keyboard, both its octaves where there is room; the knobs a sheet at the
/// foot while it is upright, and a column down the right on its side.
@MainActor
struct TabletLayoutTests {
  static let upright = SIMD2<Float>(800, 1280)
  static let onItsSide = SIMD2<Float>(1280, 800)

  static func tablet(_ size: SIMD2<Float>, _ song: Song = InterfaceTests.song()) throws -> Interface {
    let interface = try InterfaceTests.interface(song)
    interface.touch = true
    interface.size = size
    return interface
  }

  static func tap(_ interface: Interface, _ rect: Rect) {
    let at = InterfaceTests.centre(rect)
    interface.pointer(PointerEvent(phase: .began, id: 5, kind: .touch, location: at))
    interface.pointer(PointerEvent(phase: .ended, id: 5, kind: .touch, location: at))
  }

  @Test func onItsSideEveryStepIsBesideItsName() throws {
    let layout = try Self.tablet(Self.onItsSide).layout
    #expect(layout.touch && !layout.compact && !layout.sheet)
    let metrics = try #require(layout.metrics)
    #expect(metrics.shown == 16 && metrics.pages == 1 && layout.pageChips.isEmpty)
    #expect(metrics.stride >= GridMetrics.fingerStride && metrics.stepHeight >= 40, "a finger's size")
    let lane = try #require(layout.lanes.first)
    #expect(lane.header.maxX <= layout.step(0, in: lane.frame).x, "the name beside the steps")
    let grid = try #require(layout.grid)
    #expect(layout.step(15, in: lane.frame).maxX <= grid.maxX, "and all of them in it")
    // The transport a desktop's, with the chip to perform, and the tempo and swing in the strip.
    let perform = try #require(layout.chips.first { $0.action == .perform })
    #expect(perform.frame.maxX <= layout.title.x, "clear of the song's name")
    let strip = try #require(layout.strip)
    #expect(layout.numbers.map(\.target) == [.tempo, .songSwing])
    #expect(layout.numbers.allSatisfy { $0.cell.y >= strip.y && $0.cell.height >= 30 }, "in the strip")
  }

  @Test func uprightTheStepsArePaged() throws {
    let interface = try Self.tablet(Self.upright)
    var layout = interface.layout
    #expect(layout.touch && layout.sheet)
    let metrics = try #require(layout.metrics)
    #expect(metrics.shown == 8 && metrics.pages == 2, "sixteen would be narrower than a finger")
    #expect(metrics.label == GridMetrics.labelWidth && metrics.stride >= GridMetrics.fingerStride)
    let chip = try #require(layout.pageChips.last)
    Self.tap(interface, chip.frame)
    layout = interface.layout
    let lane = try #require(layout.lanes.first)
    #expect(
      layout.action(at: InterfaceTests.centre(layout.step(8, in: lane.frame)))
        == .step(pattern: "p", voice: lane.voice.id, index: 8), "the second page's first step is the ninth")
  }

  /// Upright, a sheet across the foot, its knobs in a row rather than three to one; on its side, the
  /// desktop's column, and the grid beside it still showing every step.
  @Test func theKnobsAreASheetUprightAndAColumnOnItsSide() throws {
    let upright = try Self.tablet(Self.upright)
    upright.perform(.select(voice: "909.bd"))
    var layout = upright.layout
    var panel = try #require(layout.inspector)
    #expect(panel.frame.width == layout.bar.width && panel.frame.maxY == Self.upright.y - Layout.margin)
    #expect(try #require(layout.grid).maxY <= panel.frame.y, "the grid above it")
    let voice = panel.knobs.filter { if case .voice = $0.target { true } else { false } }
    #expect(voice.count == 6 && Set(voice.map(\.cell.y)).count == 1, "the six knobs in one row")

    upright.perform(.effects)
    panel = try #require(upright.layout.inspector)
    #expect(panel.frame.maxY == Self.upright.y - Layout.margin)
    #expect(Set(panel.labels.map(\.y)).count == 2, "the effects' four groups two by two")
    #expect(panel.knobs.allSatisfy { $0.cell.maxX <= panel.frame.maxX && $0.cell.maxY <= panel.frame.maxY })

    let onItsSide = try Self.tablet(Self.onItsSide)
    onItsSide.perform(.select(voice: "909.bd"))
    layout = onItsSide.layout
    panel = try #require(layout.inspector)
    #expect(
      panel.frame.width == Layout.inspectorWidth && panel.frame.maxX == layout.bar.maxX, "down the right")
    #expect(try #require(layout.grid).maxX <= panel.frame.x)
    #expect(layout.metrics?.shown == 16, "and every step still beside it")
  }

  /// A 303 step tapped opens the keyboard, as on a phone: on an upright tablet, both octaves at a
  /// finger's size, and no octave to choose.
  @Test func a303StepOpensBothOctaves() throws {
    var song = InterfaceTests.song()
    song.patterns[0].bass["303.a"] = Array(repeating: BassStep(note: 0), count: 16)
    let interface = try Self.tablet(Self.upright, song)
    let line = try #require(interface.layout.bassLines.first)
    #expect(line.header.maxX <= line.cells.x, "its name beside its steps")
    Self.tap(interface, Rect(line.cells.x, line.cells.y, 20, line.cells.height))
    let keyboard = try #require(interface.keyboard)
    #expect(interface.bassSelection?.index == 0)
    #expect(keyboard.keys.count == 25 && keyboard.keys.map(\.note).max() == 24, "C1 to C3")
    #expect(!keyboard.chips.contains { if case .octave = $0.action { true } else { false } })
    #expect(keyboard.keys.filter { !$0.black }.allSatisfy { $0.frame.width >= 40 })
    let grid = try #require(interface.layout.grid)
    #expect(keyboard.frame.maxY <= grid.y, "clear of the grid")
    let high = try #require(keyboard.keys.first { $0.note == 19 })
    Self.tap(interface, high.frame)
    #expect(interface.session.song?.patterns[0].bassStep("303.a", at: 0).note == 19, "G2")

    // A small tablet has room for one octave, and keeps the chip that changes it.
    let small = try Self.tablet(SIMD2(600, 960), song)
    small.perform(.bassStep(voice: "303.a", index: 0))
    let one = try #require(small.keyboard)
    #expect(one.keys.count == 13 && one.chips.contains { $0.label == "C1–C2" })
  }

  /// A desktop window the size of a tablet is laid out as a desktop's: only a touchscreen is a tablet.
  @Test func aDesktopWindowAsLargeIsUnchanged() throws {
    let interface = try InterfaceTests.interface()
    interface.size = Self.upright
    let layout = interface.layout
    #expect(!layout.touch && !layout.sheet)
    #expect(layout.metrics?.shown == 16 && layout.metrics?.touch == false)
    #expect(!layout.chips.contains { $0.action == .perform })
  }
}
