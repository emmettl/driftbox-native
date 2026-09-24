import DriftboxEngine
import DriftboxInterface
import DriftboxSeq
import DriftboxSession
import DriftboxShell
import Testing

/// The controls on a phone in portrait, 372 points across: a page of eight steps at a finger's
/// size, the names above them, the grid dragged and swiped rather than scrolled with a wheel, and
/// the controls put away for performing.
@MainActor
struct PhoneLayoutTests {
  static func phone() throws -> Interface {
    let interface = try InterfaceTests.interface()
    interface.size = SIMD2(372, 828)
    return interface
  }

  static func finger(_ phase: PointerEvent.Phase, _ at: SIMD2<Float>) -> PointerEvent {
    PointerEvent(phase: phase, id: 7, kind: .touch, location: at)
  }

  @Test func eightStepsAtAFingersSize() throws {
    let layout = try Self.phone().layout
    #expect(layout.compact)
    let metrics = try #require(layout.metrics)
    #expect(metrics.shown == 8 && metrics.pages == 2)
    #expect(metrics.cell >= 36, "a finger's width: \(metrics.cell)")
    #expect(metrics.stepHeight >= 40)
    let lane = try #require(layout.lanes.first)
    let last = layout.step(7, in: lane.frame)
    #expect(last.maxX <= 372 - Layout.margin, "the eighth on the screen: \(last.maxX)")
    #expect(lane.header.maxY <= layout.step(0, in: lane.frame).y, "the name above the steps")
    #expect(layout.chips.allSatisfy { $0.frame.maxX <= layout.bar.maxX }, "the transport fits")
    #expect(layout.chips.contains { $0.action == .perform })
  }

  @Test func theSecondPageIsTheLastEight() throws {
    let interface = try Self.phone()
    let chip = try #require(interface.layout.pageChips.last)
    #expect(chip.label == "9–16")
    InterfaceTests.click(interface, InterfaceTests.centre(chip.frame))
    let layout = interface.layout
    #expect(layout.metrics?.first == 8)
    let lane = try #require(layout.lanes.first)
    #expect(
      layout.action(at: InterfaceTests.centre(layout.step(8, in: lane.frame)))
        == .step(pattern: "p", voice: lane.voice.id, index: 8), "its first step is the ninth")
  }

  @Test func aSwipeAcrossTurnsThePage() throws {
    let interface = try Self.phone()
    let lane = try #require(interface.layout.lanes.first)
    let from = InterfaceTests.centre(interface.layout.step(5, in: lane.frame))
    let before = interface.session.song
    #expect(interface.pointer(Self.finger(.began, from)))
    interface.pointer(Self.finger(.moved, from + SIMD2(-40, 2)))
    interface.pointer(Self.finger(.ended, from + SIMD2(-120, 4)))
    #expect(interface.page == 1, "to the left: the next page")
    #expect(interface.session.song == before, "and no step set on the way")
  }

  @Test func aDragUpScrollsTheGrid() throws {
    // A pattern with every drum in it is taller than a phone.
    var song = InterfaceTests.song()
    for voice in allVoices { song.patterns[0].tracks[voice.id] = Array(repeating: .off, count: 16) }
    let tall = try InterfaceTests.interface(song)
    tall.size = SIMD2(372, 828)
    let layout = tall.layout
    #expect(layout.maxScroll > 0)
    let lane = try #require(layout.lanes.first)
    let from = InterfaceTests.centre(layout.step(2, in: lane.frame))
    let before = tall.session.song
    tall.pointer(Self.finger(.began, from))
    tall.pointer(Self.finger(.moved, from - SIMD2(0, 60)))
    tall.pointer(Self.finger(.ended, from - SIMD2(0, 60)))
    #expect(tall.scroll > 50, "up with the finger: \(tall.scroll)")
    #expect(tall.session.song == before, "and no step set")
  }

  @Test func performingLeavesTheScreenToThePad() throws {
    let interface = try Self.phone()
    let perform = try #require(interface.layout.chips.first { $0.action == .perform })
    InterfaceTests.click(interface, InterfaceTests.centre(perform.frame))
    #expect(interface.performing)
    let lane = try #require(interface.layout.lanes.first)
    #expect(
      !interface.pointer(Self.finger(.began, InterfaceTests.centre(lane.frame))),
      "where the grid was is the pad's")
    #expect(interface.pointer(Self.finger(.began, InterfaceTests.centre(interface.editChip))))
    interface.pointer(Self.finger(.ended, InterfaceTests.centre(interface.editChip)))
    #expect(!interface.performing, "and the chip in the corner brings the controls back")
  }

  /// The tempo and the swing, which the transport has no room for, in the strip's head, at a
  /// finger's height and clear of the sections; dragged up, the tempo goes up.
  @Test func theTempoAndSwingAreInTheStrip() throws {
    let interface = try Self.phone()
    let layout = interface.layout
    let strip = try #require(layout.strip)
    let sections = try #require(layout.sectionsFrame)
    #expect(layout.numbers.map(\.target) == [.tempo, .songSwing])
    for number in layout.numbers {
      let cell = number.cell
      #expect(cell.x >= strip.x && cell.maxX <= strip.maxX && cell.y >= strip.y, "in the strip: \(cell)")
      #expect(cell.maxY <= sections.y, "above its sections")
      #expect(cell.height >= 30 && cell.width >= 80, "a finger's size: \(cell)")
    }
    let tempo = try #require(layout.numbers.first).cell
    let from = SIMD2(tempo.x + tempo.width / 2, tempo.y + tempo.height / 2)
    interface.pointer(Self.finger(.began, from))
    interface.pointer(Self.finger(.moved, from - SIMD2(0, 20)))
    interface.pointer(Self.finger(.ended, from - SIMD2(0, 20)))
    #expect(interface.session.song?.bpm == 130, "twenty points up, ten beats a minute faster")
  }

  /// A voice's knobs, and the effects, as a sheet across the foot of the screen, with the grid
  /// above it rather than under it; and a knob on it turned with a finger.
  @Test func theKnobsAreASheet() throws {
    let interface = try Self.phone()
    let lane = try #require(interface.layout.lanes.first)
    InterfaceTests.click(interface, InterfaceTests.centre(lane.header))
    var layout = interface.layout
    var sheet = try #require(layout.inspector)
    #expect(sheet.voice == lane.voice.id)
    #expect(sheet.frame.x == layout.bar.x && sheet.frame.width == layout.bar.width, "across the screen")
    #expect(sheet.frame.maxY == 828 - Layout.margin, "at its foot: \(sheet.frame)")
    let grid = try #require(layout.grid)
    #expect(grid.maxY <= sheet.frame.y, "the grid above it: \(grid)")
    #expect(sheet.knobs.allSatisfy { $0.cell.width >= 80 && $0.cell.maxX <= sheet.frame.maxX }, "roomy knobs")

    let level = try #require(sheet.knobs.first)
    let before = level.target.value(in: try #require(interface.session.song))
    let from = InterfaceTests.centre(level.cell)
    interface.pointer(Self.finger(.began, from))
    interface.pointer(Self.finger(.moved, from - SIMD2(0, 34)))
    interface.pointer(Self.finger(.ended, from - SIMD2(0, 34)))
    let after = level.target.value(in: try #require(interface.session.song))
    #expect(after > before || after == level.target.range.upperBound, "turned up: \(before) to \(after)")

    let fx = try #require(layout.chips.first { $0.action == .effects })
    InterfaceTests.click(interface, InterfaceTests.centre(fx.frame))
    layout = interface.layout
    sheet = try #require(layout.inspector)
    #expect(sheet.voice == nil && sheet.frame.maxY == 828 - Layout.margin, "the effects the same way")
    #expect(try #require(layout.grid).maxY <= sheet.frame.y)
  }

  @Test func aDesktopIsUnchanged() throws {
    let layout = try InterfaceTests.interface().layout
    #expect(!layout.compact && layout.pageChips.isEmpty)
    #expect(layout.metrics?.shown == 16 && layout.metrics?.label == GridMetrics.labelWidth)
    #expect(!layout.chips.contains { $0.action == .perform })
  }
}
