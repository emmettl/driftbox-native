import DriftboxEngine
import DriftboxSeq
import DriftboxSession

/// A rectangle in points, from the window's top left.
public struct Rect: Equatable, Sendable {
  public var x: Float
  public var y: Float
  public var width: Float
  public var height: Float

  public init(_ x: Float, _ y: Float, _ width: Float, _ height: Float) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var maxX: Float { x + width }
  public var maxY: Float { y + height }

  public func contains(_ point: SIMD2<Float>) -> Bool {
    point.x >= x && point.x < maxX && point.y >= y && point.y < maxY
  }

  /// Grown by `amount` on every side, or shrunk by a negative one.
  func outset(_ amount: Float) -> Rect {
    Rect(x - amount, y - amount, width + amount * 2, height + amount * 2)
  }
}

/// What pressing something on the interface does.
public enum Action: Equatable, Sendable {
  case toggle
  case start
  case loop
  case metronome
  /// Cycle a drum step through off, on and accented; or on a 909 lane, flam it, as the flam mode
  /// or the option key held says.
  case step(pattern: String, voice: String, index: Int)
  /// Cycle a step of the pattern-controlled filter.
  case filterStep(pattern: String, index: Int)
  /// Show a voice's knobs, or hide them if they are showing.
  case select(voice: String)
  /// Show a voice's knobs, whatever is showing.
  case show(voice: String)
  /// Set a 303 step's note, or pause it if that note is already set there.
  case note(pattern: String, voice: String, index: Int, note: Int)
  case bassAccent(pattern: String, voice: String, index: Int)
  case bassSlide(pattern: String, voice: String, index: Int)
  /// Strike a voice, as the panel's "hit it" does.
  case hit(voice: String)
  /// Put the panel away.
  case close
  /// A knob, which a press turns by dragging rather than does anything to when it lifts.
  case knob(KnobTarget)
  /// Play from a bar of the song, as a section of the strip does.
  case seek(bar: Int)
  /// Show whichever pattern is playing.
  case follow
  /// Show a pattern to edit, whatever is playing.
  case showPattern(String)
  /// Add a pattern the length of the one shown, and show it.
  case addPattern
  /// Show the song's effects down the right, or put them away.
  case effects
}

/// A 303 line's rows, as the Mac draws them: two octaves of notes from the top, then a row each
/// for accent and slide.
public enum BassMetrics {
  /// The notes, top row first.
  public static let notes = Array((0...24).reversed())
  public static let noteHeight: Float = 7
  public static let noteStride: Float = 8.5
  public static let flagHeight: Float = 13
  public static let flagStride: Float = 16
  public static var notesHeight: Float { Float(notes.count) * noteStride }
  /// Where the flag rows start, below a small gap under the notes.
  public static var flagsTop: Float { notesHeight + 4 }
  public static var height: Float { flagsTop + flagStride * 2 }
  /// The black keys, counting up from C, whose rows are shaded as on a piano roll.
  public static let blackKeys: Set<Int> = [1, 3, 6, 8, 10]
}

/// Where the grid's columns fall, as the Mac's grid has them: a step lines up with the same step
/// all the way down, and the columns stretch with the window between a size that can be hit and
/// one that still reads as a row.
public struct GridMetrics: Equatable, Sendable {
  public static let labelWidth: Float = 112
  public static let gap: Float = 4
  public static let minimumStride: Float = 22
  public static let maximumStride: Float = 88

  public let steps: Int
  /// From one column's left edge to the next.
  public let stride: Float

  public init(steps: Int, width: Float) {
    self.steps = max(1, steps)
    let room = (width - Self.labelWidth - 8) / Float(self.steps)
    stride = min(Self.maximumStride, max(Self.minimumStride, room))
  }

  public var cell: Float { stride - Self.gap }
  /// A little taller than wide while the columns are narrow, and no taller than thirty points.
  public var stepHeight: Float { min(30, max(22, cell * 1.2)) }
}

/// Where everything on the interface is, for a window `size` points across, and what each part
/// does when pressed. Made afresh from the session for every frame and every press, which is cheap:
/// it is arithmetic, and the drawing reads it as the pointer does, so the two cannot disagree.
public struct Layout {
  public static let margin: Float = 12
  public static let barHeight: Float = 44
  public static let inset: Float = 12

  public struct Chip {
    public var frame: Rect
    public var label: String
    public var action: Action
    public var isOn: Bool
  }

  public struct Lane {
    public var voice: Voice
    /// Its index in `allVoices`, which is what `Session.struck` counts in.
    public var index: Int
    public var frame: Rect
    public var header: Rect
  }

  public struct BassLine {
    /// `303.a` or `303.b`.
    public var voice: String
    public var frame: Rect
    public var header: Rect
    /// Where the notes and flags are: the first step's column at its left.
    public var cells: Rect

    public var name: String { voice == "303.a" ? "303 A" : "303 B" }
  }

  public var size: SIMD2<Float>
  public var bar: Rect
  public var chips: [Chip]
  /// Where the song's name and the transport's readout go, between the chips.
  public var title: Rect
  public var readout: Rect
  /// The numbers dragged in the readout: the tempo, unless an outside clock sets it, and the swing.
  public var numbers: [Knob] = []

  /// The song's strip under the transport, and its sections, or nil with no song.
  public var strip: Rect?
  public var sections: [Section] = []
  /// Where the sections are drawn, inside the strip.
  public var sectionsFrame: Rect?
  /// The song's length in bars.
  public var totalBars = 0

  /// The grid's panel, and what is in it, or nil with no song.
  public var grid: Rect?
  /// The row of patterns at the grid's head, which stays put as the grid scrolls under it.
  public var patternBar: Rect?
  public var patternChips: [Chip] = []
  /// Where the grid's rows are, and are seen: the panel under its pattern bar.
  public var gridContent: Rect?
  public var pattern: DriftboxSeq.Pattern?
  public var metrics: GridMetrics?
  public var ruler: Rect?
  public var lanes: [Lane] = []
  public var filterLane: Rect?
  public var bassLines: [BassLine] = []
  /// The selected voice's panel, down the right under the transport, or nil with none selected.
  public var inspector: Inspector?
  /// The step the playhead is on, in the pattern shown, or nil when it is not playing there.
  public var playhead: Int?
  /// How far the grid's content is scrolled up inside its panel, kept to what there is.
  public var scroll: Float = 0
  /// How far it can be.
  public var maxScroll: Float = 0

  /// The layout for a window `size` points across, the grid scrolled up by `scroll`, and the song's
  /// effects down the right if `effects`, or the selected voice's knobs if not.
  @MainActor
  public init(session: Session, size: SIMD2<Float>, scroll: Float = 0, effects: Bool = false) {
    self.size = size
    let margin = Self.margin
    bar = Rect(margin, margin, max(0, size.x - margin * 2), Self.barHeight)
    let chipY = bar.y + 8
    let chipHeight = bar.height - 16
    var chips: [Chip] = [
      Chip(
        frame: Rect(bar.x + 10, chipY, 60, chipHeight), label: session.isPlaying ? "STOP" : "PLAY",
        action: .toggle, isOn: session.isPlaying),
      Chip(frame: Rect(bar.x + 76, chipY, 48, chipHeight), label: "TOP", action: .start, isOn: false),
    ]
    let loopChip = Rect(bar.maxX - 10 - 56, chipY, 56, chipHeight)
    let clickChip = Rect(loopChip.x - 6 - 64, chipY, 64, chipHeight)
    let fxChip = Rect(clickChip.x - 6 - 44, chipY, 44, chipHeight)
    chips.append(Chip(frame: fxChip, label: "FX", action: .effects, isOn: effects && session.song != nil))
    chips.append(Chip(frame: clickChip, label: "CLICK", action: .metronome, isOn: session.metronome))
    chips.append(Chip(frame: loopChip, label: "LOOP", action: .loop, isOn: session.loop != nil))
    self.chips = chips
    let left = bar.x + 136
    let middle = max(left, (left + fxChip.x - 12) / 2)
    title = Rect(left, bar.y, max(0, middle - left), bar.height)
    readout = Rect(middle, bar.y, max(0, fxChip.x - 12 - middle), bar.height)
    if session.song != nil {
      let swing = Rect(readout.maxX - 82, chipY, 82, chipHeight)
      numbers.append(Knob(target: .songSwing, dial: swing, cell: swing))
      if session.followedBPM == nil {
        let tempo = Rect(swing.x - 4 - 76, chipY, 76, chipHeight)
        numbers.insert(Knob(target: .tempo, dial: tempo, cell: tempo), at: 0)
      }
    }

    guard let song = session.song else { return }
    let strip = Rect(margin, bar.maxY + margin, bar.width, Self.stripHeight)
    self.strip = strip
    let sectionsFrame = Rect(strip.x + 14, strip.y + 26, max(0, strip.width - 28), 24)
    self.sectionsFrame = sectionsFrame
    (sections, totalBars) = Self.sections(of: song, in: sectionsFrame)
    let below = strip.maxY + margin

    inspector =
      effects
      ? Self.effects(top: below, right: bar.maxX)
      : session.selectedVoice.flatMap { Self.inspector(for: $0, top: below, right: bar.maxX) }
    guard let pattern = session.shownPattern else { return }
    self.pattern = pattern
    // The playhead only means something on the pattern that is playing, and only while it is.
    if session.isPlaying, session.position?.pattern?.id == pattern.id { playhead = session.position?.step }

    // Beside the panel, when there is one.
    let width = max(0, (inspector.map { $0.frame.x - margin } ?? size.x - margin) - margin)
    let metrics = GridMetrics(steps: pattern.length, width: width - Self.inset * 2)
    self.metrics = metrics
    let voices = allVoices.enumerated().filter { pattern.tracks[$0.element.id] != nil }
    let lines = ["303.a", "303.b"].filter { pattern.bass[$0] != nil }
    let laneHeight = metrics.stepHeight + 4
    let filterHeight = metrics.stepHeight * 0.8
    let lineHeight = BassMetrics.height + 12
    let content =
      8 + 5 + Float(voices.count) * (laneHeight + 5) + 5 + filterHeight
      + Float(lines.count) * (10 + lineHeight)
    // As tall as what is in it and its pattern bar, up to the room under the strip; past that, it
    // scrolls under the pattern bar.
    let head = Self.patternBarHeight + 16
    let room = max(0, size.y - margin - below)
    let height = min(head + content + Self.inset + 8, room)
    let grid = Rect(margin, size.y - margin - height, width, height)
    self.grid = grid
    maxScroll = max(0, head + content + Self.inset + 8 - height)
    self.scroll = min(max(0, scroll), maxScroll)
    let patternBar = Rect(grid.x + Self.inset, grid.y + 8, width - Self.inset * 2, Self.patternBarHeight)
    self.patternBar = patternBar
    patternChips = Self.patternChips(session: session, song: song, shown: pattern, in: patternBar)
    let rows = Rect(grid.x, patternBar.maxY + 8, width, max(0, grid.maxY - patternBar.maxY - 8))
    gridContent = rows

    let x = grid.x + Self.inset
    let inner = width - Self.inset * 2
    var y = rows.y + 8 - self.scroll
    ruler = Rect(x + GridMetrics.labelWidth + 4, y, metrics.stride * Float(metrics.steps), 8)
    y += 8 + 5
    for (index, voice) in voices {
      lanes.append(
        Lane(
          voice: voice, index: index, frame: Rect(x, y, inner, laneHeight),
          header: Rect(x + 4, y + 2, GridMetrics.labelWidth, metrics.stepHeight)))
      y += laneHeight + 5
    }
    filterLane = Rect(x, y + 5, inner, filterHeight)
    y += 5 + filterHeight
    for voice in lines {
      y += 10
      let frame = Rect(x, y, inner, lineHeight)
      bassLines.append(
        BassLine(
          voice: voice, frame: frame, header: Rect(x + 4, y + 6, GridMetrics.labelWidth, 28),
          cells: Rect(
            x + 4 + GridMetrics.labelWidth, y + 6, metrics.stride * Float(metrics.steps) - GridMetrics.gap,
            BassMetrics.height)))
      y += lineHeight
    }
  }

  /// Where a lane's `index`th step is.
  public func step(_ index: Int, in lane: Rect) -> Rect {
    guard let metrics else { return Rect(0, 0, 0, 0) }
    let height = lane == filterLane ? metrics.stepHeight * 0.8 : metrics.stepHeight
    let top = lane == filterLane ? lane.y : lane.y + 2
    return Rect(
      lane.x + 4 + GridMetrics.labelWidth + Float(index) * metrics.stride, top, metrics.cell, height)
  }

  /// The panels, which is where a press is the interface's and not the pad's.
  public var panels: [Rect] { [bar] + [strip, grid, inspector?.frame].compactMap { $0 } }

  /// What pressing at `point` would do, if anything.
  public func action(at point: SIMD2<Float>) -> Action? {
    if let chip = chips.first(where: { $0.frame.contains(point) }) { return chip.action }
    if let number = numbers.first(where: { $0.cell.contains(point) }) { return .knob(number.target) }
    if let section = sections.first(where: { $0.frame.contains(point) }) { return .seek(bar: section.start) }
    if let inspector, inspector.frame.contains(point) {
      if let chip = inspector.chips.first(where: { $0.frame.contains(point) }) { return chip.action }
      return inspector.knobs.first { $0.cell.contains(point) }.map { .knob($0.target) }
    }
    if let chip = patternChips.first(where: { $0.frame.contains(point) }) { return chip.action }
    // The rows only where they are seen, under the pattern bar.
    guard let gridContent, gridContent.contains(point), let pattern, let metrics else { return nil }
    for lane in lanes {
      if lane.header.contains(point) { return .select(voice: lane.voice.id) }
      guard lane.frame.contains(point) else { continue }
      if let index = column(at: point.x, lane: lane.frame, metrics: metrics),
        step(index, in: lane.frame).contains(point), index < pattern.trackLength(lane.voice.id)
      {
        return .step(pattern: pattern.id, voice: lane.voice.id, index: index)
      }
    }
    if let filterLane, let index = column(at: point.x, lane: filterLane, metrics: metrics),
      step(index, in: filterLane).contains(point)
    {
      return .filterStep(pattern: pattern.id, index: index)
    }
    for line in bassLines {
      if line.header.contains(point) { return .select(voice: line.voice) }
      if line.cells.contains(point) {
        return bassAction(at: point, in: line, pattern: pattern, metrics: metrics)
      }
    }
    return nil
  }

  /// A note's row, the accent's or the slide's, in the column under `point`; nothing in the gap
  /// between two columns.
  private func bassAction(
    at point: SIMD2<Float>, in line: BassLine, pattern: DriftboxSeq.Pattern, metrics: GridMetrics
  ) -> Action? {
    let local = point - SIMD2(line.cells.x, line.cells.y)
    let column = local.x / metrics.stride
    guard column >= 0, Int(column) < pattern.length,
      column - column.rounded(.down) <= metrics.cell / metrics.stride
    else { return nil }
    let index = Int(column)
    if local.y < BassMetrics.notesHeight {
      let row = Int(max(0, local.y) / BassMetrics.noteStride)
      guard row < BassMetrics.notes.count else { return nil }
      return .note(pattern: pattern.id, voice: line.voice, index: index, note: BassMetrics.notes[row])
    }
    if local.y >= BassMetrics.flagsTop, local.y < BassMetrics.flagsTop + BassMetrics.flagStride {
      return .bassAccent(pattern: pattern.id, voice: line.voice, index: index)
    }
    if local.y >= BassMetrics.flagsTop + BassMetrics.flagStride, local.y < BassMetrics.height {
      return .bassSlide(pattern: pattern.id, voice: line.voice, index: index)
    }
    return nil
  }

  /// Where the `index`th step's cell for `note` is, in a 303 line.
  public func noteCell(_ note: Int, step index: Int, in line: BassLine) -> Rect {
    guard let metrics, let row = BassMetrics.notes.firstIndex(of: note) else { return Rect(0, 0, 0, 0) }
    return Rect(
      line.cells.x + Float(index) * metrics.stride, line.cells.y + Float(row) * BassMetrics.noteStride,
      metrics.cell, BassMetrics.noteHeight)
  }

  /// Where the `index`th step's accent flag is, or its slide flag below it.
  public func flagCell(step index: Int, slide: Bool, in line: BassLine) -> Rect {
    guard let metrics else { return Rect(0, 0, 0, 0) }
    return Rect(
      line.cells.x + Float(index) * metrics.stride,
      line.cells.y + BassMetrics.flagsTop + (slide ? BassMetrics.flagStride : 0), metrics.cell,
      BassMetrics.flagHeight)
  }

  private func column(at x: Float, lane: Rect, metrics: GridMetrics) -> Int? {
    let along = x - (lane.x + 4 + GridMetrics.labelWidth)
    guard along >= 0 else { return nil }
    let index = Int(along / metrics.stride)
    return index < metrics.steps ? index : nil
  }
}
