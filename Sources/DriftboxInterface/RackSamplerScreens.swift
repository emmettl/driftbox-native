import DriftboxCanvas
import DriftboxRack
import DriftboxRackSession

/// The Sampler's and the Audio Track's faces drawn as the Mac draws them: a recording's shape on a
/// recessed screen, what it is, and where a file goes when there is none.
extension RackInterface {
  static let recordingFill = Colour(0x04090c)

  /// A slice of the sample: lit teal when it is the one chosen.
  func drawSlice(_ button: RackStage.Button, accent: Bool, on canvas: Canvas) {
    let r = button.frame
    canvas.fill = button.isOn ? Theme.nine : Theme.white(0.04)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 2)
    canvas.stroke = accent ? Theme.white(0.18) : Theme.edge
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 2)
    guard !button.label.isEmpty else { return }
    canvas.align = .center
    canvas.font = Theme.mono(7)
    canvas.fill = button.isOn ? Theme.ground : Theme.dim
    canvas.fillText(button.label, r.midX, r.midY + 2.5)
  }

  /// An empty screen asking for a file: what to do, and what it takes.
  func drawPrompt(_ button: RackStage.Button, detail: String, hovered: Bool, on canvas: Canvas) {
    let r = button.frame
    if hovered && button.press != nil {
      canvas.fill = Theme.white(0.03)
      canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 6)
    }
    canvas.align = .center
    canvas.font = Theme.mono(11, weight: 600)
    canvas.fill = Theme.ink
    canvas.fillText(button.label, r.midX, r.midY - 1)
    canvas.font = Theme.mono(8)
    canvas.fill = Theme.dim
    canvas.fillText(detail, r.midX, r.midY + 12)
  }

  /// The recessed screen a recording is drawn on and dropped on.
  func drawRecordingScreen(_ r: Rect, on canvas: Canvas) {
    canvas.fill = Self.recordingFill
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 6)
    canvas.stroke = Theme.nine.faded(0.2)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 6)
  }

  /// A recording's peaks as bars about a centre line.
  func drawWave(_ r: Rect, peaks: [Double], on canvas: Canvas) {
    canvas.stroke = Theme.nine.faded(0.2)
    canvas.lineWidth = 0.7
    canvas.strokeLines([(SIMD2(r.x, r.midY), SIMD2(r.maxX, r.midY))])
    guard !peaks.isEmpty else { return }
    let step = r.width / Float(peaks.count)
    let width = max(1, step * 0.78)
    canvas.fill = Theme.nine.faded(0.85)
    for (index, peak) in peaks.enumerated() {
      let height = max(1, Float(peak) * r.height * 0.81)
      canvas.fillRect(r.x + Float(index) * step, r.midY - height / 2, width, height)
    }
  }

  /// What a recording is, beside the button that loads it: its name, and its length, or why the
  /// last file could not be read.
  private func describe(
    _ name: String?, detail: String?, empty: String, module: String, at x: Float, _ baseline: Float,
    width: Float, on canvas: Canvas
  ) {
    canvas.align = .left
    canvas.fill = Theme.ink
    canvas.fillText(
      Draw.fit(name ?? empty, width: width, size: 9, weight: 600, on: canvas), x, baseline)
    canvas.font = Theme.mono(7.5)
    if let detail {
      canvas.fill = Theme.dim
      canvas.fillText(detail, x, baseline + 11)
    } else if let failure = rack.loadFailure, failure.module == module {
      canvas.fill = Theme.eight
      canvas.fillText(
        Draw.fit(failure.reason, width: width, size: 7.5, weight: 400, on: canvas), x, baseline + 11)
    }
  }

  /// The Slice Lab's screen: the sample's shape over its slices; and under it what the sample is,
  /// the bars it is taken to be, and the slice being played.
  func drawSampleScreen(_ r: Rect, face: RackStage.Face, on canvas: Canvas) {
    let module = face.module.id
    let info = rack.samples[module]
    drawRecordingScreen(r, on: canvas)
    if let info {
      drawWave(Rect(r.x + 8, r.y + 6, r.width - 16, r.height - 32), peaks: info.peaks, on: canvas)
    }
    let bars = face.buttons.first { if case .sampleBars = $0.press { true } else { false } }
    describe(
      info?.name,
      detail: info.map {
        "\($0.source == .break ? "factory break" : "local file") · \(RackDisplay.fixed($0.seconds, 2))s"
      },
      empty: "No sample loaded", module: module, at: r.x + 84, r.maxY + 15,
      width: (bars?.frame.x ?? r.maxX) - 40 - (r.x + 84), on: canvas)
    if let bars {
      canvas.align = .right
      canvas.font = Theme.mono(7.5)
      canvas.fill = Theme.dim
      canvas.fillText("BARS", bars.frame.x - 6, bars.frame.maxY - 3.5)
    }
    // The slice being played, over the buttons that step it round, and its name under them.
    if let down = face.buttons.first(where: { $0.label == "‹" }) {
      let slices = max(1, min(32, Int(value(face, "slices").rounded())))
      let selected = max(0, min(slices - 1, Int(value(face, "slice").rounded())))
      let middle = down.frame.maxX + 2
      canvas.align = .center
      canvas.font = Theme.mono(9.5, weight: 600)
      canvas.fill = Theme.ink
      canvas.fillText("\(selected + 1)", middle, down.frame.y - 7)
      canvas.font = Theme.mono(8.5, weight: 500)
      canvas.fill = Theme.dim
      canvas.fillText("SLICE", middle, down.frame.y + 33)
    }
  }

  /// The Audio Track's screen: its recording's shape; and under it what the recording is and
  /// where on the timeline it starts.
  func drawTrackScreen(_ r: Rect, face: RackStage.Face, on canvas: Canvas) {
    let module = face.module.id
    let track = rack.tracks[module]
    drawRecordingScreen(r, on: canvas)
    if let track {
      drawWave(Rect(r.x + 8, r.y + 6, r.width - 16, r.height - 12), peaks: track.peaks, on: canvas)
    }
    let row = r.maxY + 6 + Float(RackLayout.cellHeight) / 2
    let start = face.cells.first?.frame.x ?? r.maxX
    describe(
      track?.name,
      detail: track.map { "\($0.stereo ? "stereo" : "mono") · \(RackDisplay.fixed($0.seconds, 2))s" },
      empty: "No recording loaded", module: module, at: r.x + 84, row - 2, width: start - 80 - (r.x + 84),
      on: canvas)
    canvas.align = .right
    canvas.font = Theme.mono(7.5)
    canvas.fill = Theme.dim
    canvas.fillText("START", start - 4 - canvas.measure("BAR") - 8, row + 3)
  }
}
