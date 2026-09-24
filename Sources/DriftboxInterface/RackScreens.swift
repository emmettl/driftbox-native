import DriftboxCanvas
import DriftboxRack
import DriftboxRackSession
import Foundation

/// The faces that meter, drawn as the Mac draws them from what the render thread last copied out:
/// the tuner's display, the meter's needle, lights or scope, and the looper's screen and transport.
/// There is no blur on the canvas, so a glow is the same stroke again, wider and faint, underneath.
extension RackInterface {
  static let screenFill = Colour(0x030c0c)

  /// The screen a face meters on, and what it says in its title beyond its words.
  func drawScreen(_ face: RackStage.Face, hovered: SIMD2<Float>?, on canvas: Canvas) {
    let reading = rack.readings[face.module.id]
    if let screen = face.screen {
      switch face.module.type {
      case "tuner": drawTuner(screen, face: face, reading: reading, on: canvas)
      case "meter":
        drawPeak(face, reading: reading, on: canvas)
        drawMeter(screen, face: face, reading: reading, on: canvas)
      case "looper": drawLooper(screen, face: face, reading: reading, on: canvas)
      case "scale-player": drawScaleScreen(screen, face: face, on: canvas)
      case "note-echo": drawEchoScreen(screen, face: face, on: canvas)
      case "chord-player": drawChordScreen(screen, face: face, on: canvas)
      case "arp": drawArpScreen(screen, face: face, on: canvas)
      case "combi": drawRoutes(screen, face: face, on: canvas)
      case "sampler": drawSampleScreen(screen, face: face, on: canvas)
      case "audio-track": drawTrackScreen(screen, face: face, on: canvas)
      case "multisampler": drawAtlasScreen(screen, face: face, on: canvas)
      default: break
      }
    }
    if face.module.type == "arranger" { drawArrangerLabels(face, on: canvas) }
    for button in face.buttons {
      drawButton(button, hovered: hovered.map(button.frame.contains) ?? false, on: canvas)
    }
    for (index, cell) in face.cells.enumerated() {
      let held = turning?.target == .cell(module: face.module.id, index: index)
      drawCell(cell, lit: held || hovered.map(cell.frame.contains) == true, on: canvas)
    }
  }

  func value(_ face: RackStage.Face, _ id: String) -> Double {
    face.def?.params.first { $0.id == id }.map { rack.value(face.module, $0) } ?? 0
  }

  // MARK: The tuner

  /// The note, big, with its octave; the frequency and the cents either side; and a needle across
  /// ±50 cents that lights the display when it is within five.
  func drawTuner(_ r: Rect, face: RackStage.Face, reading: MeterReading?, on canvas: Canvas) {
    let tuning = RackDisplay.tuning(
      frequency: reading?.frequency ?? 0, reference: value(face, "reference"), clarity: reading?.clarity ?? 0)
    let inTune = tuning.detected && abs(tuning.cents) <= 5
    let colour = tuning.detected ? Theme.nine : Theme.ink.faded(0.35)
    if inTune {
      canvas.stroke = Theme.nine.faded(0.22)
      canvas.lineWidth = 5
      canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 6)
    }
    canvas.fill = Colour(0x0b2723)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 6, foot: Self.screenFill)
    canvas.stroke = Theme.nine.faded(inTune ? 0.7 : 0.2)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 6)

    canvas.save()
    canvas.clip(r.x, r.y, r.width, r.height)
    canvas.font = Theme.mono(8)
    canvas.fill = colour
    canvas.align = .left
    canvas.fillText(
      tuning.detected ? RackDisplay.fixed(tuning.frequency, 1) + " Hz" : "NO SIGNAL", r.x + 8, r.y + 19)
    canvas.align = .right
    let cents = (tuning.cents >= 0 ? "+" : "") + RackDisplay.fixed(tuning.cents, 1) + "¢"
    canvas.fillText(tuning.detected ? cents : "—", r.maxX - 8, r.y + 19)

    // The note, and its octave raised beside it.
    canvas.font = Theme.mono(30, weight: 700)
    let note = canvas.measure(tuning.note)
    canvas.font = Theme.mono(10)
    let octave = tuning.octave.map(String.init) ?? ""
    let across = note + 2 + canvas.measure(octave)
    let left = r.x + (r.width - across) / 2
    let baseline = r.y + 4 + 28
    canvas.align = .left
    canvas.font = Theme.mono(30, weight: 700)
    canvas.fill = colour.faded(0.25)
    canvas.fillText(tuning.note, left + 0.5, baseline + 0.5)
    canvas.fill = colour
    canvas.fillText(tuning.note, left, baseline)
    canvas.font = Theme.mono(10)
    canvas.fillText(octave, left + note + 2, baseline - 14)

    // The scale across ±50 cents, and the needle on it.
    let (from, to) = (r.x + 12, r.maxX - 12)
    let base = r.maxY - 16
    canvas.fill = Theme.ink.faded(0.18)
    canvas.fillRect(from, base, to - from, 1)
    canvas.align = .center
    canvas.font = Theme.mono(6)
    for tick in [-50, -25, 0, 25, 50] {
      let x = from + (to - from) * Float(tick + 50) / 100
      let height: Float = tick == 0 ? 15 : 10
      canvas.fill = tick == 0 ? Theme.nine.faded(0.65) : Theme.ink.faded(0.25)
      canvas.fillRect(x, base + 4 - height, 1, height)
      canvas.fill = Theme.ink.faded(0.38)
      canvas.fillText(tick > 0 ? "+\(tick)" : "\(tick)", x, base + 14)
    }
    let x = from + (to - from) * Float((max(-50, min(50, tuning.cents)) + 50) / 100)
    canvas.fill = colour.faded(0.35)
    canvas.fillRoundedRect(x - 2.5, base - 20, 5, 21, radius: 2.5)
    canvas.fill = colour
    canvas.fillRoundedRect(x - 1, base - 18, 2, 17, radius: 1)
    canvas.restore()
  }

  // MARK: The meter

  /// The meter's title: a peak light that lights past full scale.
  func drawPeak(_ face: RackStage.Face, reading: MeterReading?, on canvas: Canvas) {
    let clipped = (reading?.peak ?? 0) > 1
    canvas.font = Theme.mono(7)
    let width = canvas.measure("PEAK") + 8
    let chip = Rect(face.title.maxX - 62 - 8 - width, face.title.midY - 5.5, width, 11)
    if clipped {
      canvas.fill = Theme.eight.faded(0.35)
      canvas.fillRoundedRect(chip.x - 2, chip.y - 2, chip.width + 4, chip.height + 4, radius: 4)
      canvas.fill = Theme.eight
      canvas.fillRoundedRect(chip.x, chip.y, chip.width, chip.height, radius: 3)
    }
    canvas.stroke = Theme.eight.faded(clipped ? 1 : 0.2)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(chip.x, chip.y, chip.width, chip.height, radius: 3)
    canvas.align = .center
    canvas.fill = clipped ? Colour(0xfff2fb) : Theme.eight.faded(0.3)
    canvas.fillText("PEAK", chip.midX, chip.maxY - 3)
  }

  /// A moving-coil needle, a bar of lights, or a scope, as the meter's mode says.
  func drawMeter(_ r: Rect, face: RackStage.Face, reading: MeterReading?, on canvas: Canvas) {
    let mode = max(0, min(2, Int(value(face, "mode").rounded())))
    let level = reading?.level ?? 0
    let position = RackDisplay.meterPosition(mode == 0 ? reading?.envelope ?? 0 : level)
    canvas.fill = Colour(0x08070b)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 7)
    canvas.stroke = Theme.white(0.18)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 7)
    switch mode {
    case 0: drawNeedle(r.inset(5, 5, 5, 5), position: position, on: canvas)
    case 1: drawLights(r.inset(9, 10, 7, 10), lit: Int((position * 18).rounded()), on: canvas)
    default:
      drawScope(r.inset(5, 5, 5, 5), waveform: reading?.waveform ?? [], peak: reading?.peak ?? 0, on: canvas)
    }
  }

  static let needleTicks: [(db: Double, label: String)] = [
    (-40, "−40"), (-20, "−20"), (-10, "−10"), (-5, "−5"), (0, "0"), (3, "+3"),
  ]

  /// The moving-coil face: a cream dial, a scale from −40 to +3, and a red needle on a pivot below
  /// the bottom edge.
  func drawNeedle(_ r: Rect, position: Double, on canvas: Canvas) {
    canvas.save()
    canvas.clip(r.x, r.y, r.width, r.height)
    canvas.fill = Colour(0xfff7ce)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 4, foot: Colour(0xd9c78a))
    let pivot = SIMD2(r.midX, r.maxY + 17)
    func along(_ degrees: Double, _ radius: Float) -> SIMD2<Float> {
      let angle = Float(degrees * .pi / 180)
      return pivot + SIMD2(sin(angle), -cos(angle)) * radius
    }
    canvas.align = .center
    canvas.font = Theme.mono(7)
    canvas.lineWidth = 1
    for tick in Self.needleTicks {
      let angle = -50 + RackDisplay.meterPosition(pow(10, tick.db / 20)) * 100
      let hot = tick.db > 0
      canvas.stroke = hot ? Colour(0xc53b34) : Colour(0x514528)
      canvas.strokeLines([(along(angle, 90), along(angle, 99))])
      let at = along(angle, 82)
      canvas.fill = hot ? Colour(0xb52f2b) : Colour(0x514528)
      canvas.fillText(tick.label, at.x, at.y + 2.5)
    }
    canvas.font = Theme.mono(8, weight: 700)
    canvas.fill = Colour(0x302817)
    canvas.fillText("VU", pivot.x, r.maxY - 18)
    let angle = -50 + position * 100
    let foot = pivot - SIMD2(0, 1)
    let tip = foot + (along(angle, 100) - pivot)
    canvas.stroke = Colour(0x5c0d0b, alpha: 0.35)
    canvas.lineWidth = 3
    canvas.strokeLines([(foot, tip)])
    canvas.stroke = Colour(0xd13936)
    canvas.lineWidth = 2
    canvas.strokeLines([(foot, tip)])
    canvas.fill = Colour(0x887c5f)
    canvas.fillRoundedRect(pivot.x - 9, r.maxY + 6, 18, 18, radius: 9, foot: Colour(0x211e18))
    canvas.restore()
  }

  /// Eighteen lights: green, amber from the thirteenth, pink from the seventeenth.
  func drawLights(_ r: Rect, lit: Int, on canvas: Canvas) {
    let count = 18
    let gap: Float = 3
    let width = (r.width - gap * Float(count - 1)) / Float(count)
    let height = max(0, r.height - 13 - gap)
    for index in 0..<count {
      let colour = index >= 16 ? Theme.eight : index >= 12 ? Theme.three : Theme.nine
      let on = index < lit
      let x = r.x + Float(index) * (width + gap)
      if on {
        canvas.fill = colour.faded(0.3)
        canvas.fillRoundedRect(x - 2, r.y - 2, width + 4, height + 4, radius: 3)
      }
      canvas.fill = on ? colour : colour.faded(0.08)
      canvas.fillRoundedRect(x, r.y, width, height, radius: 2)
      canvas.stroke = on ? Theme.white(0.7) : colour.faded(0.11)
      canvas.lineWidth = 1
      canvas.strokeRoundedRect(x, r.y, width, height, radius: 2)
    }
    canvas.font = Theme.mono(7)
    canvas.fill = Theme.ink.faded(0.45)
    let labels = ["−48", "−18", "−6", "+3"]
    let widths = labels.map(canvas.measure)
    let space = (r.width - widths.reduce(0, +)) / Float(labels.count - 1)
    var x = r.x
    canvas.align = .left
    for (label, width) in zip(labels, widths) {
      canvas.fillText(label, x, r.maxY - 3)
      x += width + space
    }
  }

  /// The scope: the last block's shape on a green graticule.
  func drawScope(_ r: Rect, waveform: [Float], peak: Double, on canvas: Canvas) {
    canvas.save()
    canvas.clip(r.x, r.y, r.width, r.height)
    canvas.fill = Colour(0x0c2723)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 4, foot: Colour(0x020c0b))
    graticule(r, spacing: 18, colour: Theme.nine.faded(0.06), on: canvas)
    trace(r.inset(5, 6, 16, 6), waveform: waveform, on: canvas)
    canvas.align = .right
    canvas.font = Theme.mono(7)
    canvas.fill = Theme.nine.faded(0.65)
    canvas.fillText(RackDisplay.meterLabel(peak) + " PEAK", r.maxX - 7, r.maxY - 5)
    canvas.restore()
  }

  // MARK: The looper

  /// What is in the loop and where the playhead is, over a graticule, with the mode, the length
  /// and the most it holds across the top.
  func drawLooper(_ r: Rect, face: RackStage.Face, reading: MeterReading?, on canvas: Canvas) {
    let mode = max(0, min(3, Int(value(face, "mode").rounded())))
    let seconds = reading?.loopSeconds ?? 0
    let recording = mode == 1 || mode == 3
    canvas.fill = Colour(0x03100e)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 6)
    canvas.save()
    canvas.clip(r.x, r.y, r.width, r.height)
    graticule(r, spacing: 15, colour: Theme.nine.faded(0.04), on: canvas)
    trace(
      r.inset(18, 7, 17, 7), waveform: reading?.waveform ?? [],
      head: seconds > 0 ? max(0, min(1, reading?.loopPosition ?? 0)) : nil, on: canvas)
    // Pinned left, centre and right, as the reference places them, so a narrow screen overlaps
    // them rather than wrapping them.
    canvas.font = Theme.mono(7.5)
    let baseline = r.y + 13
    canvas.align = .left
    if recording {
      canvas.fill = Theme.eight.faded(0.35)
      canvas.fillText(RackFaces.loopModes[mode], r.x + 7.5, baseline + 0.5)
    }
    canvas.fill = recording ? Theme.eight : Theme.nine.faded(0.65)
    canvas.fillText(RackFaces.loopModes[mode], r.x + 7, baseline)
    canvas.align = .center
    canvas.fill = Theme.nine.faded(0.65)
    canvas.fillText(RackDisplay.loopTime(seconds), r.midX, baseline)
    canvas.align = .right
    canvas.fill = Theme.ink.faded(0.32)
    canvas.fillText("30s MAX", r.maxX - 7, baseline)
    canvas.restore()
    canvas.stroke = Theme.nine.faded(0.2)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 6)
  }

  /// A transport button: small capitals, lit in its colour when it is the one chosen.
  func drawButton(_ button: RackStage.Button, hovered: Bool, on canvas: Canvas) {
    switch button.style {
    case .transport: break
    case .option, .tag: return drawOption(button, hovered: hovered, on: canvas)
    case .key(let black, let root): return drawKey(button, black: black, root: root, on: canvas)
    case .pulse(let amount): return drawPulse(button, amount: amount, on: canvas)
    case .capsule: return drawCapsule(button, on: canvas)
    case .voice(let lane, let badge): return drawVoice(button, lane: lane, badge: badge, on: canvas)
    case .arpStep(let number, let octave):
      return drawArpStep(button, number: number, octave: octave, on: canvas)
    case .learn(let armed, let bound): return drawLearn(button, armed: armed, bound: bound, on: canvas)
    case .pad(let live): return drawPad(button, live: live, hovered: hovered, on: canvas)
    case .slice(let accent): return drawSlice(button, accent: accent, on: canvas)
    case .prompt(let detail): return drawPrompt(button, detail: detail, hovered: hovered, on: canvas)
    case .zone(let root, let note): return drawZone(button, root: root, note: note, on: canvas)
    case .chip:
      return Draw.chip(
        button.frame, label: button.label, isOn: false, hovered: hovered, down: false, tint: button.tint,
        size: 10,
        on: canvas)
    }
    let r = button.frame
    if button.isOn {
      canvas.fill = button.tint.faded(0.25)
      canvas.fillRoundedRect(r.x - 2, r.y - 2, r.width + 4, r.height + 4, radius: 5)
    }
    canvas.fill = button.isOn ? button.tint : Theme.white(hovered ? 0.08 : 0.025)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 4)
    canvas.stroke = button.isOn ? button.tint : Theme.ink.faded(0.14)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 4)
    canvas.align = .center
    canvas.font = Theme.mono(7)
    canvas.fill = button.isOn ? Theme.ground : button.text ?? Theme.ink.faded(0.55)
    canvas.fillText(button.label, r.midX, r.midY + 2.5)
  }

  // MARK: Shared

  /// A square grid, for a screen's background.
  func graticule(_ r: Rect, spacing: Float, colour: Colour, on canvas: Canvas) {
    var lines: [(SIMD2<Float>, SIMD2<Float>)] = []
    var x = r.x
    while x <= r.maxX {
      lines.append((SIMD2(x, r.y), SIMD2(x, r.maxY)))
      x += spacing
    }
    var y = r.y
    while y <= r.maxY {
      lines.append((SIMD2(r.x, y), SIMD2(r.maxX, y)))
      y += spacing
    }
    canvas.stroke = colour
    canvas.lineWidth = 1
    canvas.strokeLines(lines)
  }

  /// A waveform drawn across its box, over a faint centre line, glowing; and where the playhead
  /// is, when there is one.
  func trace(_ r: Rect, waveform: [Float], head: Double? = nil, on canvas: Canvas) {
    canvas.stroke = Theme.nine.faded(0.18)
    canvas.lineWidth = 0.7
    canvas.strokeLines([(SIMD2(r.x, r.midY), SIMD2(r.maxX, r.midY))])
    let points = RackDisplay.waveformPoints(waveform, width: Double(r.width), height: Double(r.height)).map {
      SIMD2(r.x + Float($0.x), r.y + Float($0.y))
    }
    let segments = Array(zip(points, points.dropFirst()))
    canvas.stroke = Theme.nine.faded(0.25)
    canvas.lineWidth = 4
    canvas.strokeLines(segments)
    canvas.stroke = Theme.nine
    canvas.lineWidth = 1.5
    canvas.strokeLines(segments)
    if let head {
      let x = r.x + Float(head) * r.width
      canvas.stroke = Theme.three.faded(0.3)
      canvas.lineWidth = 3.5
      canvas.strokeLines([(SIMD2(x, r.y), SIMD2(x, r.maxY))])
      canvas.stroke = Theme.three
      canvas.lineWidth = 1.2
      canvas.strokeLines([(SIMD2(x, r.y), SIMD2(x, r.maxY))])
    }
  }
}
