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

  public var size: SIMD2<Float>
  public var bar: Rect
  public var chips: [Chip]
  /// Where the song's name and the transport's readout go, between the chips.
  public var title: Rect
  public var readout: Rect

  /// The grid's panel, and what is in it, or nil with no song.
  public var grid: Rect?
  public var pattern: DriftboxSeq.Pattern?
  public var metrics: GridMetrics?
  public var ruler: Rect?
  public var lanes: [Lane] = []
  public var filterLane: Rect?
  /// The step the playhead is on, in the pattern shown, or nil when it is not playing there.
  public var playhead: Int?

  @MainActor
  public init(session: Session, size: SIMD2<Float>) {
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
    chips.append(Chip(frame: clickChip, label: "CLICK", action: .metronome, isOn: session.metronome))
    chips.append(Chip(frame: loopChip, label: "LOOP", action: .loop, isOn: session.loop != nil))
    self.chips = chips
    let left = bar.x + 136
    let middle = max(left, (left + clickChip.x - 12) / 2)
    title = Rect(left, bar.y, max(0, middle - left), bar.height)
    readout = Rect(middle, bar.y, max(0, clickChip.x - 12 - middle), bar.height)

    guard session.song != nil, let pattern = session.shownPattern else { return }
    self.pattern = pattern
    // The playhead only means something on the pattern that is playing, and only while it is.
    if session.isPlaying, session.position?.pattern?.id == pattern.id { playhead = session.position?.step }

    let width = max(0, size.x - margin * 2)
    let metrics = GridMetrics(steps: pattern.length, width: width - Self.inset * 2)
    self.metrics = metrics
    let voices = allVoices.enumerated().filter { pattern.tracks[$0.element.id] != nil }
    let laneHeight = metrics.stepHeight + 4
    let filterHeight = metrics.stepHeight * 0.8
    let content = 8 + 5 + Float(voices.count) * (laneHeight + 5) + 5 + filterHeight
    let height = content + Self.inset * 2
    let top = max(bar.maxY + margin, size.y - margin - height)
    let grid = Rect(margin, top, width, height)
    self.grid = grid

    let x = grid.x + Self.inset
    var y = grid.y + Self.inset
    ruler = Rect(x + GridMetrics.labelWidth + 4, y, metrics.stride * Float(metrics.steps), 8)
    y += 8 + 5
    for (index, voice) in voices {
      lanes.append(
        Lane(
          voice: voice, index: index, frame: Rect(x, y, width - Self.inset * 2, laneHeight),
          header: Rect(x + 4, y + 2, GridMetrics.labelWidth, metrics.stepHeight)))
      y += laneHeight + 5
    }
    filterLane = Rect(x, y + 5, width - Self.inset * 2, filterHeight)
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
  public var panels: [Rect] { [bar] + (grid.map { [$0] } ?? []) }

  /// What pressing at `point` would do, if anything.
  public func action(at point: SIMD2<Float>) -> Action? {
    if let chip = chips.first(where: { $0.frame.contains(point) }) { return chip.action }
    guard let grid, grid.contains(point), let pattern, let metrics else { return nil }
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
    return nil
  }

  private func column(at x: Float, lane: Rect, metrics: GridMetrics) -> Int? {
    let along = x - (lane.x + 4 + GridMetrics.labelWidth)
    guard along >= 0 else { return nil }
    let index = Int(along / metrics.stride)
    return index < metrics.steps ? index : nil
  }
}
