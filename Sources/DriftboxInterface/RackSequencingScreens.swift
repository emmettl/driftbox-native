import DriftboxCanvas
import DriftboxRack
import DriftboxRackSession

/// The sequencing faces drawn as the Mac draws them: the Tracker's steps and the Arranger's
/// numbers, the Scale Player's keyboard, and the Note Echo's pulses, each on its own screen.
extension RackInterface {
  // MARK: Buttons

  /// A choice's button, as the generic face draws one; or, for a tag, its words alone.
  func drawOption(_ button: RackStage.Button, hovered: Bool, on canvas: Canvas) {
    let r = button.frame
    let fade = button.opacity
    canvas.align = .center
    if button.style == .tag {
      canvas.font = Theme.mono(9)
      canvas.fill = (hovered ? Theme.ink : Theme.dim).faded(fade)
      canvas.fillText(button.label, r.midX, r.midY + 3)
      return
    }
    canvas.fill = (button.isOn ? button.tint : Theme.white(hovered ? 0.14 : 0.06)).faded(fade)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 4)
    canvas.font = Theme.mono(9, weight: button.isOn ? 600 : 400)
    canvas.fill = (button.isOn ? Theme.ground : Theme.ink.faded(0.75)).faded(fade)
    canvas.fillText(button.label, r.midX, r.maxY - 3.5)
  }

  /// A key of the scale's keyboard, rounded at the bottom only: lit in amber or violet when the
  /// scale has it, with its note, and ROOT on the first.
  func drawKey(_ button: RackStage.Button, black: Bool, root: Bool, on canvas: Canvas) {
    let r = button.frame
    let on = button.isOn
    if on {
      canvas.fill = button.tint.faded(0.3)
      canvas.fillRoundedRect(r.x - 2, r.y, r.width + 4, r.height + 3, radius: 5)
    }
    let top: Colour
    let foot: Colour
    if on {
      (top, foot) = black ? (Colour(0xffe1a0), Theme.three) : (Colour(0xded5ff), Theme.nine)
    } else {
      top = black ? Colour(0x020205, alpha: 0.82) : Colour(0xe2e0ee, alpha: 0.07)
      foot = top
    }
    // Square at the top: the rounded shape, with its upper corners filled in.
    canvas.fill = top
    canvas.fillRect(r.x, r.y, r.width, 4)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 4, foot: foot)
    canvas.stroke = on ? button.tint.faded(0.85) : Theme.ink.faded(0.16)
    canvas.lineWidth = 1
    canvas.save()
    canvas.clip(r.x - 1, r.y + 4, r.width + 2, r.height)
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 4)
    canvas.restore()
    canvas.strokeLines([
      (SIMD2(r.x + 0.5, r.y), SIMD2(r.x + 0.5, r.y + 4)),
      (SIMD2(r.maxX - 0.5, r.y), SIMD2(r.maxX - 0.5, r.y + 4)),
      (SIMD2(r.x, r.y + 0.5), SIMD2(r.maxX, r.y + 0.5)),
    ])
    canvas.align = .center
    canvas.fill = on ? (black ? Colour(0x291500) : Colour(0x100a20)) : Theme.ink.faded(0.36)
    if root {
      canvas.font = Theme.mono(6)
      canvas.fillText("ROOT", r.midX, r.y + 10)
    }
    canvas.font = Theme.mono(8)
    canvas.fillText(button.label, r.midX, r.maxY - 6)
  }

  /// One of the echo's pulses: a bar as tall as its velocity, lit when it sounds, over its number.
  func drawPulse(_ button: RackStage.Button, amount: Double, on canvas: Canvas) {
    let r = button.frame
    let fade = button.opacity
    let lit = button.isOn
    canvas.fill = (lit ? Theme.three.faded(0.12) : Theme.white(0.02)).faded(fade)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 3)
    canvas.stroke = (lit ? Theme.three.faded(0.72) : Theme.ink.faded(0.1)).faded(fade)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 3)
    let height = max(3, Float(amount) * 44)
    let bar = Rect(r.x + 3, r.maxY - 13 - height, r.width - 6, height)
    if lit {
      canvas.fill = Theme.three.faded(0.3)
      canvas.fillRoundedRect(bar.x - 2, bar.y - 2, bar.width + 4, bar.height + 4, radius: 3)
      canvas.fill = Colour(0xffdf94)
      canvas.fillRect(bar.x, bar.maxY - 2, bar.width, 2)
      canvas.fillRoundedRect(bar.x, bar.y, bar.width, bar.height, radius: 2, foot: Theme.three)
    } else {
      canvas.fill = Theme.dim.faded(0.16 * fade)
      canvas.fillRect(bar.x, bar.maxY - 2, bar.width, 2)
      canvas.fillRoundedRect(bar.x, bar.y, bar.width, bar.height, radius: 2)
    }
    canvas.align = .center
    canvas.font = Theme.mono(7)
    canvas.fill = (lit ? Colour(0x2b1700) : Theme.ink.faded(0.36)).faded(fade)
    canvas.fillText(button.label, r.midX, r.maxY - 3)
  }

  // MARK: Numbers

  /// A step, lit amber when it plays; or a plain number, as the arranger's are. Edged in teal under
  /// the pointer or while it is dragged.
  func drawCell(_ cell: RackStage.Cell, lit: Bool, on canvas: Canvas) {
    let r = cell.frame
    let fade = cell.opacity
    if let caption = cell.caption {
      canvas.align = .right
      canvas.font = Theme.mono(7.5)
      canvas.fill = Theme.dim.faded(fade)
      canvas.fillText(caption, r.x - 4, r.midY + 3)
    }
    let playing = cell.isStep && cell.value != 0
    canvas.fill = (playing ? Theme.three : Colour(0x000000, alpha: 0.35)).faded(fade)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 3)
    canvas.stroke =
      (lit
      ? Theme.nine.faded(0.9)
      : playing ? Theme.three : cell.accent ? Theme.white(0.18) : Theme.edge).faded(fade)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 3)
    guard !cell.isStep || cell.value != 0 else { return }
    canvas.align = .center
    canvas.font = Theme.mono(cell.isStep ? 9 : 10)
    canvas.fill = (playing ? Theme.ground : Theme.ink).faded(fade)
    canvas.fillText("\(cell.value)", r.midX, r.midY + 3.5)
  }

  /// The arranger's headings over each column, and each section's number beside its row.
  func drawArrangerLabels(_ face: RackStage.Face, on canvas: Canvas) {
    canvas.align = .center
    canvas.font = Theme.mono(8)
    canvas.fill = Theme.dim
    let rows = RackFaces.arrangerSections / 2
    for column in 0..<2 {
      let at = column * rows * 2
      guard face.cells.indices.contains(at + 1) else { continue }
      let (pattern, bars) = (face.cells[at], face.cells[at + 1])
      canvas.fillText("PTN", pattern.frame.midX, pattern.frame.y - 4)
      canvas.fillText("BARS", bars.frame.midX, bars.frame.y - 4)
    }
    canvas.align = .right
    canvas.font = Theme.mono(9)
    for index in stride(from: 0, to: face.cells.count, by: 2) {
      let cell = face.cells[index]
      canvas.fill = Theme.dim.faded(cell.opacity)
      canvas.fillText("\(index / 2 + 1)", cell.frame.x - 3, cell.frame.midY + 3)
    }
  }

  // MARK: Screens

  /// The scale's screen, lit from the top, and what it says along its foot.
  func drawScaleScreen(_ r: Rect, face: RackStage.Face, on canvas: Canvas) {
    canvas.fill = Colour(0x1d1533)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 6, foot: Colour(0x07050d))
    canvas.stroke = Theme.violet.faded(0.23)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 6)
    let scale = Int(value(face, "scale").rounded())
    let filtering = Int(value(face, "filter").rounded()) == 1
    let count = RackFaces.mask(scale, face.module.data["customScale"] ?? []).filter { $0 >= 0.5 }.count
    footer(
      r, inset: 10,
      [
        ("\(count) notes", Theme.dim),
        (scale == RackFaces.customScale ? "CUSTOM MAP" : "CLICK A KEY TO CUSTOMISE", Theme.nine),
        (filtering ? "WRONG NOTES SILENT" : "NEAREST NOTE · TIES DOWN", Theme.dim),
      ], on: canvas)
    canvas.fill = Theme.violet.faded(0.12)
    canvas.fillRect(r.x, r.maxY + 6, r.width, 1)
  }

  /// The echo's screen, lit from the foot, and what it says along it.
  func drawEchoScreen(_ r: Rect, face: RackStage.Face, on canvas: Canvas) {
    canvas.fill = Colour(0x0a0602)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 6, foot: Colour(0x2a1a06))
    canvas.stroke = Theme.three.faded(0.22)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 6)
    let pitch = Int(value(face, "pitch").rounded())
    footer(
      r, inset: 9,
      [
        ("VELOCITY SLOPE", Theme.dim), ("\(pitch > 0 ? "+" : "")\(pitch) ST / REPEAT", Theme.three),
        ("CLICK A PULSE TO MUTE", Theme.dim),
      ], on: canvas)
    canvas.fill = Theme.three.faded(0.12)
    canvas.fillRect(r.x, r.maxY + 6, r.width, 1)
  }

  /// Three sayings along a screen's foot: at its left, its middle and its right.
  private func footer(_ r: Rect, inset: Float, _ words: [(String, Colour)], on canvas: Canvas) {
    canvas.font = Theme.mono(7)
    let baseline = r.maxY - 6
    for ((text, colour), align) in zip(words, [Canvas.Align.left, .center, .right]) {
      canvas.align = align
      canvas.fill = colour
      let x = align == .left ? r.x + inset : align == .center ? r.midX : r.maxX - inset
      canvas.fillText(text, x, baseline)
    }
  }
}
