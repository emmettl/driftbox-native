import DriftboxCanvas
import DriftboxRack
import DriftboxRackSession

/// The Chord Player's, the Arp's and the Combinator's faces drawn as the Mac draws them: a chord's
/// voices and its Alter, an arp's rhythm steps, and what each of a combinator's controls drives.
extension RackInterface {
  // MARK: Buttons

  /// A round button, lit while it is held.
  func drawCapsule(_ button: RackStage.Button, on canvas: Canvas) {
    let r = button.frame
    let on = button.isOn
    if on {
      canvas.fill = button.tint.faded(0.3)
      canvas.fillRoundedRect(r.x - 3, r.y - 3, r.width + 6, r.height + 6, radius: r.height / 2 + 3)
    }
    canvas.fill = on ? button.tint : button.tint.faded(0.06)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: r.height / 2)
    canvas.stroke = button.tint.faded(0.56)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: r.height / 2)
    canvas.align = .center
    canvas.font = Theme.mono(7)
    canvas.fill = on ? Colour(0x211000) : button.tint
    canvas.fillText(button.label, r.midX, r.midY + 2.5)
  }

  /// One of a chord's voices: an amber key, rounder at the top, with its lane, its note and its
  /// octave; faint and named `—` when the chord has no voice there.
  func drawVoice(_ button: RackStage.Button, lane: Int, badge: String, on canvas: Canvas) {
    let r = button.frame
    let sounding = button.isOn
    if sounding {
      canvas.fill = Theme.three.faded(0.3)
      canvas.fillRoundedRect(r.x - 2, r.y - 2, r.width + 4, r.height + 4, radius: 13)
      // Round at the top, and the foot squarer: the two shapes over each other.
      canvas.fill = Colour(0xffe1a0)
      canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 12, foot: Theme.three)
      canvas.fill = Theme.three
      canvas.fillRoundedRect(r.x, r.maxY - 14, r.width, 14, radius: 4)
    } else {
      canvas.fill = Theme.three.faded(0.025)
      canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 12)
    }
    canvas.stroke = sounding ? Colour(0xffc86b, alpha: 0.92) : Theme.three.faded(0.1)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 8)
    let ink = sounding ? Colour(0x241203) : Colour(0xffeccb, alpha: 0.23)
    canvas.align = .center
    canvas.font = Theme.mono(6)
    canvas.fill = ink.faded(0.62)
    canvas.fillText("\(lane + 1)", r.midX, r.y + 10)
    canvas.font = Theme.mono(12, weight: 500)
    canvas.fill = ink
    canvas.fillText(button.label, r.midX, r.midY + 4)
    canvas.font = Theme.mono(6)
    canvas.fillText(badge, r.midX, r.maxY - 6)
  }

  /// One of an arp's rhythm steps: the note it would play, and its octave, as a warm line along
  /// the top above the root and a pink one along the foot below it; `rest` when it rests.
  func drawArpStep(_ button: RackStage.Button, number: Int, octave: Int, on canvas: Canvas) {
    let r = button.frame
    let fade = button.opacity
    let on = button.isOn
    let tint = button.tint
    canvas.save()
    canvas.clip(r.x, r.y, r.width, r.height)
    if on {
      canvas.fill = tint.faded(0.2 * fade)
      canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 4, foot: tint.faded(0.06 * fade))
    } else {
      canvas.fill = Colour(0x08060e, alpha: 0.72 * fade)
      canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 4)
    }
    canvas.stroke = tint.faded((on ? 0.18 : 0.08) * fade)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 4)
    if on && octave > 0 {
      canvas.fill = Theme.three.faded(0.22 * fade)
      canvas.fillRect(r.x, r.y, r.width, 3)
    } else if on && octave < 0 {
      canvas.fill = Theme.eight.faded(0.2 * fade)
      canvas.fillRect(r.x, r.maxY - 3, r.width, 3)
    }
    canvas.align = .center
    canvas.font = Theme.mono(5)
    canvas.fill = Theme.dim.faded(fade)
    canvas.fillText("\(number)", r.midX, r.y + 9)
    canvas.fillText(
      on ? (octave == 0 ? "root" : "\(octave > 0 ? "+" : "")\(octave)×") : "rest", r.midX, r.maxY - 5)
    canvas.font = Theme.mono(7, weight: 500)
    canvas.fill = (on ? Theme.ink.faded(0.9) : tint.faded(0.32)).faded(fade)
    canvas.fillText(button.label, r.midX, r.midY + 2.5)
    canvas.restore()
  }

  /// A control's MIDI learn: `learn`, then `turn one…` in amber while it waits, then the
  /// controller it learnt, in teal.
  func drawLearn(_ button: RackStage.Button, armed: Bool, bound: Bool, on canvas: Canvas) {
    let r = button.frame
    if armed {
      canvas.fill = Theme.three
      canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 4)
    }
    canvas.stroke = armed ? Theme.three : bound ? Theme.nine.faded(0.4) : Theme.edge
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 4)
    canvas.align = .center
    canvas.font = Theme.mono(8.5)
    canvas.fill = armed ? Theme.ground : bound ? Theme.nine : Theme.dim
    canvas.fillText(button.label, r.midX, r.maxY - 3)
  }

  /// A combinator's button: a choice's button, large, with a teal mark when it drives anything.
  func drawPad(_ button: RackStage.Button, live: Bool, hovered: Bool, on canvas: Canvas) {
    let r = button.frame
    canvas.fill = button.isOn ? button.tint : Theme.white(hovered ? 0.14 : 0.06)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 4)
    canvas.align = .center
    canvas.font = Theme.mono(12, weight: button.isOn ? 600 : 400)
    canvas.fill = button.isOn ? Theme.ground : Theme.ink.faded(0.75)
    canvas.fillText(button.label, r.midX, r.midY + 4)
    if live {
      canvas.fill = Theme.nine
      canvas.fillEllipse(r.maxX - 10, r.y + 5, 5, 5)
    }
  }

  // MARK: Screens

  /// The chord's screen, lit amber from the foot, and what it says either side of its Alter.
  func drawChordScreen(_ r: Rect, face: RackStage.Face, on canvas: Canvas) {
    canvas.fill = Colour(0x080503)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 6, foot: Colour(0x2e1807))
    canvas.stroke = Theme.three.faded(0.25)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 6)
    let notes = max(1, min(5, Int(value(face, "notes").rounded())))
    let inversion = max(0, min(4, Int(value(face, "inversion").rounded())))
    canvas.font = Theme.mono(7)
    canvas.fill = Theme.dim
    let baseline = r.maxY - 10
    canvas.align = .left
    canvas.fillText("\(notes) TERTIAN", r.x + 10, baseline)
    canvas.align = .right
    canvas.fillText(inversion == 0 ? "ROOT POSITION" : "INVERSION \(inversion)", r.maxX - 10, baseline)
    canvas.fill = Theme.three.faded(0.12)
    canvas.fillRect(r.x, r.maxY + 6, r.width, 1)
  }

  /// The arp's screen, in teal for played notes and violet for a chord's, and what it says along
  /// its foot: where the notes come from, what it is doing, and how its steps are played.
  func drawArpScreen(_ r: Rect, face: RackStage.Face, on canvas: Canvas) {
    let source = max(0, min(1, Int(value(face, "source").rounded())))
    let played = source == 1
    let tint = played ? Theme.nine : Theme.violet
    canvas.fill = Colour(0x05040a)
    canvas.fillRoundedRect(
      r.x, r.y, r.width, r.height, radius: 6, foot: played ? Colour(0x0c2c2a) : Colour(0x1c1538))
    canvas.stroke = tint.faded(0.25)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 6)

    let enabled = value(face, "enable") >= 0.5
    let hold = value(face, "hold") >= 0.5
    let insert = max(0, min(4, Int(value(face, "insert").rounded())))
    let chord = max(0, min(7, Int(value(face, "chord").rounded())))
    let length = max(1, min(RackFaces.arpSteps, Int(value(face, "patternLength").rounded())))
    let status =
      (!enabled
      ? "bypass"
      : hold
        ? "hold"
        : value(face, "singleRepeat") < 0.5
          ? "single once"
          : insert == 0 ? "live" : "insert \(RackFaces.label("arp", "insert", insert, "\(insert)"))")
      .uppercased()
    let baseline = r.maxY - 8
    canvas.font = Theme.mono(7)
    canvas.fill = Theme.dim
    canvas.align = .left
    canvas.fillText(
      source == 0
        ? "\(RackFaces.label("arp", "chord", chord, "Chord \(chord + 1)")) intervals".uppercased()
        : "HELD INPUT LANES", r.x + 10, baseline)
    canvas.align = .right
    canvas.fillText(
      "\(length) STEPS · "
        + (value(face, "velocityMode") >= 0.5
          ? "\(Int(RackDisplay.jsRound(value(face, "velocity") * 100)))% FIXED" : "PLAYED VELOCITY"),
      r.maxX - 10, baseline)
    // What it is doing, in a capsule in the middle: filled amber while it holds.
    let lit = hold && enabled
    let width = canvas.measure(status) + 16
    let capsule = Rect(r.midX - width / 2, baseline - 8, width, 11)
    if lit {
      canvas.fill = Theme.three
      canvas.fillRoundedRect(capsule.x, capsule.y, capsule.width, capsule.height, radius: 5.5)
    }
    canvas.stroke = lit ? Theme.three : Theme.violet.faded(0.2)
    canvas.strokeRoundedRect(capsule.x, capsule.y, capsule.width, capsule.height, radius: 5.5)
    canvas.align = .center
    canvas.fill = lit ? Colour(0x1c1203) : Theme.nine
    canvas.fillText(status, capsule.midX, baseline)
    canvas.fill = Theme.violet.faded(0.12)
    canvas.fillRect(r.x, r.maxY + 6, r.width, 1)
  }

  /// A combinator's routing: under each rotary what it drives — `→ 3`, `→ 3 +` when it is patched
  /// as well, `patched`, or `—` — and every route written out below its buttons, as many as fit.
  func drawRoutes(_ r: Rect, face: RackStage.Face, on canvas: Canvas) {
    let module = face.module.id
    let routes = rack.patch.modulation.filter { $0.from.module == module }
    canvas.align = .center
    canvas.font = Theme.mono(10)
    for control in face.controls {
      let id = control.param.id
      let count = routes.filter { $0.from.port == id }.count
      let patched = rack.patch.cables.contains { $0.from.module == module && $0.from.port == id }
      let doing = count > 0 ? (patched ? "→ \(count) +" : "→ \(count)") : patched ? "patched" : "—"
      canvas.fill = count > 0 || patched ? Theme.nine : Theme.dim
      canvas.fillText(doing, control.cell.midX, control.cell.maxY + 12)
    }
    canvas.save()
    canvas.clip(r.x, r.y, r.width, r.height)
    canvas.align = .left
    guard !routes.isEmpty else {
      canvas.font = Theme.mono(9)
      canvas.fill = Theme.dim
      canvas.fillText("Nothing routed yet.", r.x, r.y + 10)
      canvas.restore()
      return
    }
    let line: Float = 12
    let fits = max(1, Int(r.height / line))
    let shown = routes.count > fits ? fits - 1 : routes.count
    for (index, route) in routes.prefix(shown).enumerated() {
      let y = r.y + 10 + Float(index) * line
      let port = route.from.port
      canvas.font = Theme.mono(9, weight: 600)
      canvas.fill = Theme.three
      canvas.fillText(port.hasPrefix("button") ? "B\(port.dropFirst(6))" : "R\(port.dropFirst(6))", r.x, y)
      let type = rack.patch.modules.first { $0.id == route.to.module }?.type
      let name = type.flatMap { RackModules.registry[$0]?.params.first { $0.id == route.to.port }?.name }
      canvas.font = Theme.mono(9)
      canvas.fill = Theme.ink.faded(0.8)
      canvas.fillText("\(route.to.module) · \(name ?? route.to.port)", r.x + 30, y)
    }
    if shown < routes.count {
      canvas.font = Theme.mono(9)
      canvas.fill = Theme.dim
      canvas.fillText("and \(routes.count - shown) more", r.x + 30, r.y + 10 + Float(shown) * line)
    }
    canvas.restore()
  }
}
