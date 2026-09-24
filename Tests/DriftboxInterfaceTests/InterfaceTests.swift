import DriftboxCanvas
import DriftboxDocument
import DriftboxEngine
import DriftboxGPU
import DriftboxHost
import DriftboxInterface
import DriftboxSeq
import DriftboxSession
import DriftboxShell
import DriftboxText
import Foundation
import Testing

#if os(Windows)
  import DriftboxGPUD3D11
  import DriftboxTextWindows
#elseif canImport(Metal)
  import DriftboxGPUMetal
  import Metal
#elseif os(Linux)
  import DriftboxGPUGLES
#endif

/// The controls over the scene: where things are, what a press on each does to the session, that a
/// press is a button's — done where it lifts, if it lifts where it began — and what is drawn.
@MainActor
struct InterfaceTests {
  /// Two lanes, a 909 kick on every beat and an 808 clap on two and four, in a pattern of sixteen.
  static func song() -> Song {
    var pattern = DriftboxSeq.Pattern(id: "p", name: "Pattern 1", length: 16)
    pattern.tracks["909.bd"] = (0..<16).map { $0 % 4 == 0 ? .on : .off }
    pattern.tracks["808.cp"] = (0..<16).map { $0 % 8 == 4 ? .on : .off }
    var song = Song(bpm: 120, patterns: [pattern])
    song.chain = [ChainStep(pattern: pattern.id)]
    return song
  }

  /// A session with `song` open, and the interface on it, laid out for a window 800 by 600.
  static func interface(_ song: Song = song()) throws -> Interface {
    let session = Session(host: EngineHost(sampleRate: 48000))
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("driftbox-interface-\(UUID().uuidString).driftbox")
    try Data(SongCodec.encode(song).utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    session.open(file: url)
    let interface = Interface(session: session)
    interface.size = SIMD2(800, 600)
    return interface
  }

  static func centre(_ rect: Rect) -> SIMD2<Float> {
    SIMD2(rect.x + rect.width / 2, rect.y + rect.height / 2)
  }

  /// Press and lift at `point`, or lift at `lift`; whether the interface took each.
  @discardableResult
  static func click(
    _ interface: Interface, _ point: SIMD2<Float>, lift: SIMD2<Float>? = nil, modifiers: Modifiers = []
  ) -> (Bool, Bool) {
    let down = interface.pointer(PointerEvent(phase: .began, location: point, modifiers: modifiers))
    let up = interface.pointer(PointerEvent(phase: .ended, location: lift ?? point, modifiers: modifiers))
    return (down, up)
  }

  /// With no song there is the transport and nothing else, and nothing to play.
  @Test func withNoSongThereIsOnlyTheTransport() {
    let interface = Interface(session: Session(host: EngineHost(sampleRate: 48000)))
    interface.size = SIMD2(800, 600)
    let layout = interface.layout
    #expect(layout.grid == nil)
    #expect(layout.chips.map(\.label) == ["PLAY", "TOP", "CLICK", "LOOP"])
    #expect(layout.panels == [layout.bar])
    #expect(layout.bar.maxX == 788, "the window's width, less its margins")
  }

  /// The grid has a lane for each voice the pattern uses, in the order every grid shows them, above
  /// the filter's lane, and sits at the foot of the window; a step is where its column is on every
  /// lane.
  @Test func theGridHasALaneForEachVoice() throws {
    let layout = try Self.interface().layout
    #expect(layout.lanes.map(\.voice.id) == allVoices.map(\.id).filter { ["909.bd", "808.cp"].contains($0) })
    let grid = try #require(layout.grid)
    #expect(grid.maxY == 588)
    #expect(grid.y > layout.bar.maxY)
    let first = layout.step(3, in: layout.lanes[0].frame)
    let second = layout.step(3, in: layout.lanes[1].frame)
    let filter = layout.step(3, in: try #require(layout.filterLane))
    #expect(first.x == second.x && second.x == filter.x, "one column all the way down")
    #expect(second.y > first.y && filter.y > second.y)
    // The window, less the margins, the panel's insets and the lane names, shared by sixteen.
    #expect(layout.metrics?.stride == 39.5, "the columns share the width")
  }

  /// A press on a step cycles it, undoably, by name; on a lane's name it shows the voice's knobs.
  @Test func aStepIsCycled() throws {
    let interface = try Self.interface()
    let session = interface.session
    let layout = interface.layout
    let kick = try #require(layout.lanes.first { $0.voice.id == "909.bd" })
    #expect(Self.click(interface, Self.centre(layout.step(4, in: kick.frame))) == (true, true))
    #expect(session.shownPattern?.step("909.bd", at: 4) == .accent, "on, then accented")
    #expect(session.undoTitle == "Undo Set Step")
    Self.click(interface, Self.centre(layout.step(1, in: kick.frame)))
    #expect(session.shownPattern?.step("909.bd", at: 1) == .on, "off, then on")

    Self.click(interface, Self.centre(kick.header))
    #expect(session.selectedVoice == "909.bd")
    Self.click(interface, Self.centre(kick.header))
    #expect(session.selectedVoice == nil, "and hides them again")

    Self.click(interface, Self.centre(layout.step(2, in: try #require(layout.filterLane))))
    #expect(session.shownPattern?.pcf(at: 2) == .on, "the filter's lane cycles too")
  }

  /// A 909 step is flammed with the option key held, and an 808 step, which has no flam, is not.
  @Test func aFlamIsMarkedWithOption() throws {
    let interface = try Self.interface()
    let layout = interface.layout
    let kick = try #require(layout.lanes.first { $0.voice.id == "909.bd" })
    let clap = try #require(layout.lanes.first { $0.voice.id == "808.cp" })
    Self.click(interface, Self.centre(layout.step(0, in: kick.frame)), modifiers: .option)
    #expect(interface.session.shownPattern?.flam("909.bd", at: 0) == true)
    #expect(interface.session.shownPattern?.step("909.bd", at: 0) == .on, "and the step left as it was")
    Self.click(interface, Self.centre(layout.step(0, in: clap.frame)), modifiers: .option)
    #expect(interface.session.shownPattern?.step("808.cp", at: 0) == .on, "cycled, as ever")
  }

  /// A press that leaves what it was pressed on does nothing when it lifts — but it was the
  /// interface's press, so it is still not the pad's. A press away from the panels is not the
  /// interface's at all.
  @Test func aPressIsAButtons() throws {
    let interface = try Self.interface()
    let layout = interface.layout
    let kick = try #require(layout.lanes.first { $0.voice.id == "909.bd" })
    let step = Self.centre(layout.step(1, in: kick.frame))
    let away = Self.centre(layout.step(2, in: kick.frame))
    #expect(interface.pointer(PointerEvent(phase: .began, location: step)))
    #expect(
      interface.pointer(PointerEvent(phase: .moved, location: SIMD2(400, 300))), "still the interface's")
    #expect(interface.pointer(PointerEvent(phase: .ended, location: away)))
    #expect(interface.session.shownPattern?.step("909.bd", at: 1) == .off, "lifted elsewhere: nothing")
    #expect(interface.session.shownPattern?.step("909.bd", at: 2) == .off)
    #expect(!interface.session.canUndo)

    #expect(Self.click(interface, SIMD2(400, 200)) == (false, false), "over the scene: the pad's")
    #expect(!interface.pointer(PointerEvent(phase: .moved, location: SIMD2(400, 200))))

    interface.isShowing = false
    #expect(Self.click(interface, step) == (false, false), "hidden, the whole window is the pad's")
  }

  /// Past the end of a lane that loops shorter than the pattern, there is nothing to set.
  @Test func aShortLanesTailIsNotSet() throws {
    var song = Self.song()
    song.patterns[0].trackLengths["909.bd"] = 8
    let interface = try Self.interface(song)
    let layout = interface.layout
    let kick = try #require(layout.lanes.first { $0.voice.id == "909.bd" })
    #expect(layout.action(at: Self.centre(layout.step(7, in: kick.frame))) != nil)
    #expect(layout.action(at: Self.centre(layout.step(8, in: kick.frame))) == nil)
  }

  /// The transport's chips play, go back to the top, click and loop, and light while they are on.
  @Test func theTransportsChips() throws {
    let interface = try Self.interface()
    func chip(_ label: String) -> Layout.Chip? { interface.layout.chips.first { $0.label == label } }
    Self.click(interface, Self.centre(try #require(chip("CLICK")).frame))
    #expect(interface.session.metronome)
    #expect(chip("CLICK")?.isOn == true)
    Self.click(interface, Self.centre(try #require(chip("LOOP")).frame))
    #expect(interface.session.loop == Session.LoopRange(start: 0, bars: 1))
    #expect(chip("LOOP")?.isOn == true)
  }

  /// Narrow, the columns keep to a size that can still be hit; wide, they stop growing.
  @Test func theColumnsStretchBetweenLimits() {
    #expect(GridMetrics(steps: 16, width: 200).stride == GridMetrics.minimumStride)
    #expect(GridMetrics(steps: 16, width: 5000).stride == GridMetrics.maximumStride)
    let fitted = GridMetrics(steps: 16, width: 120 + 16 * 40)
    #expect(fitted.stride == 40)
    #expect(fitted.cell == 36)
  }

  /// Drawn: the panels are smoked glass over the scene, a lit 909 step is teal and an 808 one pink,
  /// and nothing is drawn where there is no panel.
  @Test func whatIsDrawn() throws {
    #if os(Windows)
      let device = try D3D11Device(driver: .software)
      let typesetter = try DirectWriteTypesetter()
      let interface = try Self.interface()
      let canvas = try Canvas(device: device, typesetter: typesetter)
      try canvas.begin(width: 800, height: 600)
      interface.draw(on: canvas)
      let read = try device.readPixels(canvas.finish())
      func pixel(_ point: SIMD2<Float>) -> SIMD4<Int> {
        let at = (Int(point.y) * 800 + Int(point.x)) * 4
        return SIMD4(Int(read[at + 2]), Int(read[at + 1]), Int(read[at]), Int(read[at + 3]))
      }
      let layout = interface.layout
      #expect(pixel(SIMD2(400, 200)).w == 0, "the scene, untouched")
      let glass = pixel(SIMD2(layout.bar.x + 132, layout.bar.y + 4))
      #expect(abs(glass.w - 189) <= 3, "the panel, three quarters opaque: \(glass)")
      let kick = try #require(layout.lanes.first { $0.voice.id == "909.bd" })
      let clap = try #require(layout.lanes.first { $0.voice.id == "808.cp" })
      let teal = pixel(Self.centre(layout.step(0, in: kick.frame)))
      let pink = pixel(Self.centre(layout.step(4, in: clap.frame)))
      #expect(teal.y > teal.x + 60 && teal.w == 255, "a 909 step lit teal: \(teal)")
      #expect(pink.x > pink.y + 60 && pink.w == 255, "an 808 step lit pink: \(pink)")
      let off = pixel(Self.centre(layout.step(1, in: kick.frame)))
      #expect(off.y < 60, "an unlit step is dark: \(off)")
    #endif
  }
}
