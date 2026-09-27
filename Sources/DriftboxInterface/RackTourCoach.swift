import DriftboxCanvas
import DriftboxRackSession
import DriftboxShell
import DriftboxText
import Foundation

/// A guided tour, on the platforms whose rack is drawn: the Mac's `TourCoach`, painted. A panel in
/// the rack's corner — across the top of a phone's — saying where to look, what to do and why, the
/// steps ticked as they are done, and a way past a step or out; a ring breathing round what the step
/// points at; and, once, the offer of the first tour. It decides nothing about the patch: the rack's
/// session does, from the rack as it is. At the end it says what was skipped, and offers the patch
/// the rack had before.
extension RackInterface {
  /// A button on the panel.
  enum TourButton: Equatable {
    case fold, skip, end, back, keep, notNow, take
  }

  /// The panel laid out: its frame, the words on it line by line, its buttons, and the checklist's
  /// marks, in points on the window.
  struct TourPanel {
    struct Line {
      var text: String
      var font: FontRequest
      var colour: Colour
      var x: Float
      var y: Float
      var align: Canvas.Align = .left
    }
    struct Button {
      var frame: Rect
      var label: String
      var button: TourButton
      var isOn: Bool
    }
    struct Check {
      var centre: SIMD2<Float>
      var mark: RackSession.TourMark
      var current: Bool
    }
    var frame: Rect
    var lines: [Line] = []
    var buttons: [Button] = []
    var checks: [Check] = []
    /// Where the step is, as a chip over its title.
    var place: (frame: Rect, label: String)?
    /// What a screen reader is told of it, top to bottom: a name, and what it says.
    var spoken: [(name: String, value: String?, frame: Rect)] = []

    func button(at point: SIMD2<Float>) -> TourButton? {
      buttons.first { $0.frame.contains(point) }?.button
    }
  }

  static let tourWidth: Float = 320
  static let tourPad: Float = 14

  /// The panel as it is, or nil while there is neither a tour nor the offer of one: laid out afresh
  /// only when what it shows has changed, or it was last only estimated and a canvas can now
  /// measure it.
  func tourPanel(_ stage: RackStage, measure: HelpSheet.Measure? = nil) -> TourPanel? {
    let offering = rack.tourRun == nil && rack.offersFirstTour && !tours.isEmpty
    guard rack.tourRun != nil || offering else {
      tourLaid = nil
      return nil
    }
    let run = rack.tourRun
    let key = [
      "\(stage.area)", "\(size)", run?.tour.id ?? "offer", "\(run?.marks ?? [])", "\(run?.at ?? 0)",
      "\(tourFolded)", tourEnding ?? "", run?.before?.name ?? "",
    ].joined(separator: "|")
    if let laid = tourLaid, laid.key == key, laid.measured || measure == nil { return laid.panel }
    let panel = layTour(stage, measure: measure ?? HelpSheet.estimate)
    tourLaid = (key, measure != nil, panel)
    return panel
  }

  private func layTour(_ stage: RackStage, measure: HelpSheet.Measure) -> TourPanel {
    let compact = touch && size.x < RackStage.compactWidth
    let margin = RackStage.margin
    let width =
      compact ? max(0, size.x - margin * 2) : min(Self.tourWidth, max(0, stage.area.width - margin * 2))
    let x = compact ? margin : stage.area.maxX - margin - width
    let pad = Self.tourPad
    let inner = max(0, width - pad * 2)
    let left = x + pad
    var panel = TourPanel(frame: Rect(x, stage.area.y + margin, width, 0))
    var y = panel.frame.y + pad

    /// `text` in `font`, broken onto lines no wider than the panel's inside; the y under it.
    func words(_ text: String, _ font: FontRequest, _ colour: Colour, line: Float) {
      for set in Self.wrap(text, font, width: inner, measure: measure) {
        panel.lines.append(TourPanel.Line(text: set, font: font, colour: colour, x: left, y: y + line * 0.75))
        y += line
      }
    }
    /// Buttons along the foot, from the right, onto another row where they run out of room.
    func buttons(_ list: [(String, TourButton, Bool)]) {
      y += 6
      var right = left + inner
      var row = y
      for (label, button, isOn) in list.reversed() {
        let wide = measure(label, Theme.mono(10)) + 20
        if right - wide < left, right < left + inner {
          right = left + inner
          row += 30
        }
        panel.buttons.append(
          TourPanel.Button(frame: Rect(right - wide, row, wide, 24), label: label, button: button, isOn: isOn)
        )
        right -= wide + 6
      }
      y = row + 24
    }

    guard let run = rack.tourRun else {
      // The offer: the first tour, how long it takes, and where the rest are.
      let first = tours[0]
      words("New to the rack?", Theme.sans(13.5, weight: 600), Theme.ink, line: 19)
      y += 2
      words(
        "\(first.name) takes about \(first.minutes) minutes: add an instrument, play it, and turn the rack round.",
        Theme.sans(12), Theme.ink.faded(0.72), line: 16)
      buttons([("Not Now", .notNow, false), ("Take the Tour", .take, true)])
      y += 10
      words(
        touch
          ? "Every tour is in the patch's menu, under Rack Tours." : "Every tour is in Help › Rack Tours.",
        Theme.mono(9), Theme.dim, line: 13)
      panel.frame.height = y - panel.frame.y + pad - 4
      panel.spoken.append(("New to the rack?", first.name, panel.frame))
      return panel
    }

    // The head: whose tour, how far through, and folding it away.
    let steps = run.tour.steps.count
    let fold = Rect(left + inner - 52, y, 52, 24)
    panel.buttons.append(
      TourPanel.Button(frame: fold, label: tourFolded ? "Show" : "Hide", button: .fold, isOn: false))
    panel.lines.append(
      TourPanel.Line(
        text: "GUIDED TOUR", font: Theme.mono(8.5, weight: 600), colour: Theme.dim, x: left, y: y + 8))
    let count = "\(run.marks.filter { $0 == .done }.count) of \(steps)"
    panel.lines.append(
      TourPanel.Line(
        text: count, font: Theme.mono(10), colour: Theme.dim, x: fold.x - 8, y: y + 16, align: .right))
    let named = Self.fitted(
      run.tour.name, Theme.sans(14, weight: 600),
      width: fold.x - 8 - measure(count, Theme.mono(10)) - 8 - left,
      measure: measure)
    panel.lines.append(
      TourPanel.Line(text: named, font: Theme.sans(14, weight: 600), colour: Theme.ink, x: left, y: y + 26))
    panel.spoken.append(("Guided tour: \(run.tour.name)", "\(count) steps done", Rect(left, y, inner, 30)))
    y += 34

    if !tourFolded {
      y += 6
      let from = y
      if run.at < steps, tourEnding != run.tour.id {
        let step = run.tour.steps[run.at]
        let label = step.place.uppercased()
        panel.place = (Rect(left, y, measure(label, Theme.mono(8.5, weight: 600)) + 12, 16), label)
        y += 22
        words(step.title, Theme.sans(13.5, weight: 600), Theme.ink, line: 18)
        y += 2
        words(step.body, Theme.sans(12), Theme.ink.faded(0.72), line: 16)
        panel.spoken.append((step.title, step.body, Rect(left, from, inner, y - from)))
        buttons([("Skip", .skip, false), ("End Tour", .end, false)])
      } else {
        let skipped = run.marks.filter { $0 == .skipped }.count
        let toGo = run.marks.filter { $0 == .todo }.count
        let said =
          toGo > 0
          ? "Ended with \(toGo) step\(toGo == 1 ? "" : "s") to go."
          : skipped == 0 ? "Every step done." : "Done, but for \(skipped) skipped."
        let why =
          skipped == 0
          ? "Keep going with the patch you have built, or go back to the one you had."
          : "A skipped step still ticks if you do it while this is open."
        words(said, Theme.sans(13.5, weight: 600), Theme.ink, line: 18)
        y += 2
        words(why, Theme.sans(12), Theme.ink.faded(0.72), line: 16)
        panel.spoken.append((said, why, Rect(left, from, inner, y - from)))
        buttons(
          (run.before.map { [("Back to \($0.name)", TourButton.back, false)] } ?? [])
            + [("Keep This Patch", .keep, true)])
      }
      // Every step, ticked, passed over, or to do; a phone has only room for the one it is on.
      if !compact {
        y += 12
        for (index, step) in run.tour.steps.enumerated() {
          let mark = run.marks[index]
          panel.checks.append(
            TourPanel.Check(centre: SIMD2(left + 5, y + 7), mark: mark, current: index == run.at))
          let title = Self.fitted(step.title, Theme.sans(11), width: inner - 18, measure: measure)
          panel.lines.append(
            TourPanel.Line(
              text: title, font: Theme.sans(11), colour: mark == .done ? Theme.dim : Theme.ink.faded(0.85),
              x: left + 18, y: y + 11))
          let state =
            mark == .done ? "done" : mark == .skipped ? "skipped" : index == run.at ? "now" : "to do"
          panel.spoken.append(("Step \(index + 1): \(step.title)", state, Rect(left, y, inner, 16)))
          y += 17
        }
      }
    }
    panel.frame.height = y - panel.frame.y + pad
    return panel
  }

  /// `text` broken into lines no wider than `width` in `font`.
  static func wrap(_ text: String, _ font: FontRequest, width: Float, measure: HelpSheet.Measure) -> [String]
  {
    var lines: [String] = []
    var line = ""
    for word in text.split(separator: " ") {
      let next = line.isEmpty ? String(word) : line + " " + word
      if !line.isEmpty, measure(next, font) > width {
        lines.append(line)
        line = String(word)
      } else {
        line = next
      }
    }
    if !line.isEmpty { lines.append(line) }
    return lines
  }

  /// `text` cut to `width` in `font`, with an ellipsis where it was cut.
  static func fitted(_ text: String, _ font: FontRequest, width: Float, measure: HelpSheet.Measure) -> String
  {
    guard measure(text, font) > width else { return text }
    var cut = Substring(text)
    while !cut.isEmpty, measure(String(cut) + "…", font) > width { cut = cut.dropLast() }
    return cut.trimmingCharacters(in: .whitespaces) + "…"
  }

  // MARK: - What it hears

  /// A press on the panel is the panel's, all of it, until it lifts; one lifted on the button it went
  /// down on presses it. False for a press anywhere else, which the rack takes as ever.
  func tourPointer(_ event: PointerEvent) -> Bool {
    if let held = tourPress, held.pointer == event.id {
      if event.kind == .mouse { hover = event.location }
      guard event.phase == .ended || event.phase == .cancelled else { return true }
      tourPress = nil
      if event.phase == .ended, let button = held.button,
        tourPanel(stage)?.button(at: event.location) == button
      {
        tour(button)
      }
      return true
    }
    guard event.phase == .began, let panel = tourPanel(stage), panel.frame.contains(event.location) else {
      return false
    }
    if event.kind == .mouse { hover = event.location }
    tourPress = (event.id, panel.button(at: event.location))
    return true
  }

  /// Whether `point` is on the panel, where nothing under it hears a press.
  func onTourPanel(_ point: SIMD2<Float>) -> Bool {
    tourPanel(stage)?.frame.contains(point) == true
  }

  /// What a button on the panel does.
  func tour(_ button: TourButton) {
    switch button {
    case .fold: tourFolded.toggle()
    case .skip: rack.skipTourStep()
    case .end:
      // With a patch of the rack's own to go back to, ending is a choice; without, it just ends.
      guard let run = rack.tourRun else { return }
      if run.before == nil { rack.closeTour() } else { tourEnding = run.tour.id }
    case .back:
      rack.closeTour(goingBack: true)
      fitRack()
    case .keep: rack.closeTour()
    case .notNow: rack.tourOffered = true
    case .take: if let first = tours.first { take(first) }
    }
  }

  /// `tour` taken, from its own patch, facing front and unfolded, with nothing open over the rack.
  public func take(_ tour: RackTour) {
    guide = nil
    tourFolded = false
    tourEnding = nil
    rack.startTour(tour)
    fitRack()
  }

  // MARK: - Screen readers

  /// The panel as a screen reader is told it: what it says, top to bottom, and its buttons, each
  /// pressed as a hand would press it.
  func tourNode(_ stage: RackStage, handlers: inout [String: Handler]) -> AccessibilityNode? {
    guard let panel = tourPanel(stage) else { return nil }
    func frame(_ rect: Rect) -> SIMD4<Float> { SIMD4(rect.x, rect.y, rect.width, rect.height) }
    var children = panel.spoken.enumerated().map { index, said in
      AccessibilityNode(
        id: "tour.said.\(index)", role: .text, name: said.name, value: said.value, frame: frame(said.frame))
    }
    for button in panel.buttons {
      let id = "tour.\(button.button)"
      children.append(
        AccessibilityNode(id: id, role: .button, name: button.label, frame: frame(button.frame)))
      handlers[id] = { [weak self] asked in
        if case .press = asked { self?.tour(button.button) }
      }
    }
    let name = rack.tourRun.map { "Guided tour: \($0.tour.name)" } ?? "A guided tour"
    return AccessibilityNode(
      id: "tour", role: .group, name: name, frame: frame(panel.frame), children: children)
  }

  // MARK: - Drawing

  /// Where the step's spot is on the window: a header's control, or the first module of a type.
  func tourSpotFrame(_ stage: RackStage) -> Rect? {
    switch rack.tourSpot {
    case nil: return nil
    case .transport: return stage.chips.first { $0.target == .run }?.frame
    case .flip: return stage.chips.first { $0.target == .flip }?.frame
    // The modules to add are a menu of the platform's own, which cannot be pointed into: the button
    // that opens it, then.
    case .add: return stage.chips.first { $0.target == .add }?.frame
    case .module(let type):
      guard let face = stage.faces.first(where: { $0.module.type == type }) else { return nil }
      let at = stage.origin + SIMD2(face.frame.x, face.frame.y) * stage.scale
      return Rect(at.x, at.y, face.frame.width * stage.scale, face.frame.height * stage.scale)
    }
  }

  /// A ring breathing round what the step points at: a module inside the rack's view of it, a
  /// control in the header.
  func drawTourSpot(_ stage: RackStage, on canvas: Canvas) {
    guard let spot = tourSpotFrame(stage) else { return }
    let breath = 0.55 + 0.45 * Float(sin(Date.timeIntervalSinceReferenceDate * 3.2))
    let ring = spot.outset(4)
    canvas.save()
    if case .module = rack.tourSpot {
      canvas.clip(stage.area.x, stage.area.y, stage.area.width, stage.area.height)
    }
    canvas.stroke = Theme.nine.faded(0.18 * breath)
    canvas.lineWidth = 6
    canvas.strokeRoundedRect(ring.x, ring.y, ring.width, ring.height, radius: 10)
    canvas.stroke = Theme.nine.faded(breath)
    canvas.lineWidth = 2
    canvas.strokeRoundedRect(ring.x, ring.y, ring.width, ring.height, radius: 10)
    canvas.restore()
  }

  /// The panel, over the rack.
  func drawTour(_ stage: RackStage, on canvas: Canvas) {
    guard
      let panel = tourPanel(
        stage,
        measure: { text, font in
          canvas.font = font
          return canvas.measure(text)
        })
    else { return }
    let frame = panel.frame
    canvas.fill = Colour(0x000000, alpha: 0.35)
    canvas.fillRoundedRect(frame.x + 2, frame.y + 6, frame.width, frame.height, radius: 12)
    canvas.fill = Theme.ground.faded(0.95)
    canvas.fillRoundedRect(frame.x, frame.y, frame.width, frame.height, radius: 12)
    canvas.stroke = rack.tourRun == nil ? Theme.edge : Theme.nine.faded(0.35)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(frame.x, frame.y, frame.width, frame.height, radius: 12)

    if let place = panel.place {
      canvas.fill = Theme.nine.faded(0.16)
      canvas.fillRoundedRect(place.frame.x, place.frame.y, place.frame.width, place.frame.height, radius: 8)
      canvas.font = Theme.mono(8.5, weight: 600)
      canvas.fill = Theme.nine
      canvas.align = .center
      canvas.fillText(place.label, place.frame.x + place.frame.width / 2, place.frame.y + 11.5)
    }
    for line in panel.lines {
      canvas.font = line.font
      canvas.fill = line.colour
      canvas.align = line.align
      canvas.fillText(line.text, line.x, line.y)
    }
    for check in panel.checks { drawCheck(check, on: canvas) }
    for button in panel.buttons {
      Draw.chip(
        button.frame, label: button.label, isOn: button.isOn,
        hovered: hover.map(button.frame.contains) ?? false,
        down: tourPress?.button == button.button, size: 10, on: canvas)
    }
  }

  /// A step's mark: a tick, an arrow past it, or a ring, filled for the one it is on.
  private func drawCheck(_ check: TourPanel.Check, on canvas: Canvas) {
    let c = check.centre
    switch check.mark {
    case .done:
      canvas.stroke = Theme.nine
      canvas.lineWidth = 1.6
      canvas.strokeLines([(c + SIMD2(-4, 0), c + SIMD2(-1.5, 3)), (c + SIMD2(-1.5, 3), c + SIMD2(4, -3.5))])
    case .skipped:
      canvas.stroke = Theme.dim
      canvas.lineWidth = 1.4
      canvas.strokeLines([
        (c + SIMD2(-4, 0), c + SIMD2(4, 0)), (c + SIMD2(1, -3), c + SIMD2(4, 0)),
        (c + SIMD2(1, 3), c + SIMD2(4, 0)),
      ])
    case .todo:
      if check.current {
        canvas.fill = Theme.three
        canvas.fillEllipse(c.x - 3.5, c.y - 3.5, 7, 7)
      } else {
        canvas.stroke = Theme.dim
        canvas.lineWidth = 1.2
        canvas.strokeRoundedRect(c.x - 3.5, c.y - 3.5, 7, 7, radius: 3.5)
      }
    }
  }
}
