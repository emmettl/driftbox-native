import DriftboxCanvas
import DriftboxRack
import DriftboxRackSession
import DriftboxShell
import Foundation

/// The rack, drawn on a canvas: a header with the patch, its transport, its tempo and what the keys
/// play, and under it the rack, every module's front where `RackLayout` puts it. The same on every
/// platform; it reads the rack's session and edits it, as the Mac's rack window does.
///
/// A module's front is its generic face for now — its name, what its jacks add up to, and a control
/// for every param a hand could set. The back, where the cables are, and the faces the reference
/// builds by hand come next.
@MainActor
public final class RackInterface {
  public let rack: RackSession
  /// The window's size in points.
  public var size: SIMD2<Float> = .zero
  public private(set) var scroll: Float = 0
  public private(set) var hover: SIMD2<Float>?
  /// A press the rack has, and what it was pressed on.
  public private(set) var pressed: (pointer: Int, target: RackTarget?)?
  /// A knob or the tempo being dragged: from where, what it was and is, in its own units.
  public private(set) var turning:
    (pointer: Int, target: RackTarget, fromY: Float, from: Double, value: Double)?
  /// Octaves the keys are moved from where they start, as `,` and `.` move them.
  public private(set) var octave = 0
  /// The notes the typing keys have down, by the key, so each lifts the note it played.
  private var held: [Character: Int] = [:]
  /// A knob let go of without turning, and when: a second, soon after, puts it back.
  private var lastTap: (target: RackTarget, at: ContinuousClock.Instant)?
  /// The menu the last press asked for, which the window shows as its own.
  private var menuRequest: (menu: Menu, at: SIMD2<Float>)?
  var menuActions: [String: () -> Void] = [:]
  var menuDisabled: Set<String> = []

  public init(rack: RackSession) {
    self.rack = rack
  }

  public var stage: RackStage { RackStage(rack: rack, size: size, scroll: scroll) }

  /// Points of drag for a knob's whole travel, as the groovebox's knobs have it.
  public static let travel: Float = 170

  // MARK: - The pointer

  /// Take `event`: the rack is the whole window while it shows.
  public func pointer(_ event: PointerEvent) {
    if event.kind == .mouse { hover = event.phase == .cancelled ? nil : event.location }
    switch event.phase {
    case .began:
      let stage = stage
      let target = stage.target(at: event.location)
      pressed = (event.id, target)
      switch target {
      case .knob(let module, let param):
        guard let value = value(module, param) else { break }
        turning = (event.id, target!, event.location.y, value, value)
      case .tempo:
        turning = (event.id, .tempo, event.location.y, rack.tempo, rack.tempo)
      case .module(let id):
        rack.select(id, adding: event.modifiers.contains(.control))
      case nil:
        if stage.area.contains(event.location) { rack.select(nil) }
      default:
        break
      }
    case .moved:
      guard var turn = turning, turn.pointer == event.id else { return }
      let fine = event.modifiers.contains(.option)
      let rise = Double(turn.fromY - event.location.y)
      switch turn.target {
      case .tempo:
        turn.value = max(20, min(300, (turn.from + rise * 0.5 * (fine ? 0.2 : 1)).rounded()))
      case .knob(let module, let param):
        guard let def = def(module, param) else { return }
        let span = def.max - def.min
        let fraction = span == 0 ? 0 : (turn.from - def.min) / span
        let moved = max(0, min(1, fraction + rise / Double(Self.travel) * (fine ? 0.25 : 1)))
        turn.value = def.min + moved * span
        // Heard as it turns, as the Mac's knobs are: the first move is what undo goes back to.
        rack.turn(module, param, to: turn.value)
      default:
        return
      }
      turning = turn
    case .ended:
      guard let press = pressed, press.pointer == event.id else { return }
      pressed = nil
      if let turn = turning, turn.pointer == event.id {
        turning = nil
        finish(turn)
      } else if let target = press.target, stage.target(at: event.location) == target {
        perform(target, at: event.location)
      }
    case .cancelled:
      pressed = nil
      if turning != nil { rack.endTurn() }
      turning = nil
    }
  }

  private func finish(_ turn: (pointer: Int, target: RackTarget, fromY: Float, from: Double, value: Double)) {
    switch turn.target {
    case .tempo:
      if turn.value != turn.from { rack.setTempo(turn.value) }
      rack.endTurn()
    case .knob(let module, let param):
      rack.endTurn()
      guard turn.value == turn.from else {
        lastTap = nil
        return
      }
      // Two presses soon after each other put it back where it started life.
      let now = ContinuousClock.now
      if let last = lastTap, last.target == turn.target, now - last.at < .milliseconds(400) {
        lastTap = nil
        if let def = def(module, param), turn.from != def.defaultValue {
          rack.set(module, param, to: def.defaultValue)
        }
      } else {
        lastTap = (turn.target, now)
      }
    default:
      break
    }
  }

  private func perform(_ target: RackTarget, at point: SIMD2<Float>) {
    switch target {
    case .run: rack.toggleRunning()
    case .add: menuRequest = (addMenu(), point)
    case .option(let module, let param, let value): rack.set(module, param, to: Double(value))
    case .step(let module, let param, let by):
      guard let def = def(module, param), let value = value(module, param) else { return }
      let next = max(def.min, min(def.max, value.rounded() + Double(by)))
      rack.set(module, param, to: next)
    default:
      break
    }
  }

  /// A menu a press asked for, once: the window shows it as its own, and `choose` does what is
  /// chosen from it.
  public func takeMenuRequest() -> (menu: Menu, at: SIMD2<Float>)? {
    defer { menuRequest = nil }
    return menuRequest
  }

  public func scroll(_ event: ScrollEvent) {
    scroll = RackStage(rack: rack, size: size, scroll: scroll + event.delta.y).scroll
  }

  public func pointerLeft() { hover = nil }

  // MARK: - The keys

  /// The keys, as the Mac's rack window plays them: two octaves from `z` and `q`, with `,` and `.`
  /// for the octave. False for any other key, and for anything held with more than Shift.
  public func key(_ event: KeyEvent) -> Bool {
    guard event.modifiers.subtracting(.shift).isEmpty, case .character(let typed) = event.key else {
      return false
    }
    let character = Character(typed.lowercased())
    if let semitone = RackKeyboard.keyMap[character] {
      if event.isDown {
        guard !event.isRepeat, held[character] == nil else { return true }
        let note = RackKeyboard.root + semitone + octave * 12
        held[character] = note
        rack.noteDown(note)
      } else if let note = held.removeValue(forKey: character) {
        rack.noteUp(note)
      }
      return true
    }
    guard event.isDown else { return false }
    switch character {
    case ",": octave = max(-2, octave - 1)
    case ".": octave = min(3, octave + 1)
    default: return false
    }
    return true
  }

  /// Every key let go of, as when the window stops hearing them.
  public func releaseKeys() {
    held = [:]
    rack.allNotesOff()
  }

  // MARK: - Menus

  /// The menu for the module at `point`: moving it, bypassing it, copying it, taking it out.
  public func menu(at point: SIMD2<Float>) -> Menu? {
    menuActions = [:]
    menuDisabled = []
    guard let face = stage.face(at: point) else { return nil }
    let id = face.module.id
    let index = rack.patch.modules.firstIndex { $0.id == id } ?? 0
    return Menu(
      face.def?.name ?? face.module.type,
      [
        item("Move Up", "module.up", enabled: index > 0) { self.rack.move(id, by: -1) },
        item("Move Down", "module.down", enabled: index < rack.patch.modules.count - 1) {
          self.rack.move(id, by: 1)
        },
        .separator,
        item(face.module.bypassed ? "Unbypass" : "Bypass", "module.bypass") {
          self.rack.setBypassed(id, !face.module.bypassed)
        },
        item("Duplicate", "module.duplicate") { self.rack.duplicate(id) },
        .separator,
        item("Remove", "module.remove") { self.rack.remove(id) },
      ])
  }

  /// The modules there are to add, by what they are for, as the catalogue of cards groups them.
  /// Plug-ins are not offered where there is nothing to make them.
  func addMenu() -> Menu {
    menuActions = [:]
    menuDisabled = []
    var groups: [String] = []
    var types: [String: [String]] = [:]
    for card in ModuleFace.all where RackModules.registry[card.type] != nil {
      if RackModules.pluginTypes.contains(card.type) { continue }
      let group = card.group ?? "Other"
      if types[group] == nil { groups.append(group) }
      types[group, default: []].append(card.type)
    }
    return Menu(
      "Add",
      groups.map { group in
        .submenu(
          Menu(
            group,
            (types[group] ?? []).map { type in
              item(RackModules.registry[type]?.name ?? type, "add.\(type)") { self.rack.add(type) }
            }))
      })
  }

  public func menuIsEnabled(_ id: String) -> Bool { !menuDisabled.contains(id) }

  public func choose(_ id: String) {
    guard menuIsEnabled(id), let action = menuActions[id] else { return }
    menuActions = [:]
    action()
  }

  private func item(_ title: String, _ id: String, enabled: Bool = true, _ action: @escaping () -> Void)
    -> MenuItem
  {
    menuActions[id] = action
    if !enabled { menuDisabled.insert(id) }
    return .command(title, id: id)
  }

  // MARK: - Reading the patch

  private func def(_ module: String, _ param: String) -> ParamDef? {
    guard let type = rack.patch.modules.first(where: { $0.id == module })?.type else { return nil }
    return RackModules.registry[type]?.params.first { $0.id == param }
  }

  private func value(_ module: String, _ param: String) -> Double? {
    guard let found = rack.patch.modules.first(where: { $0.id == module }), let def = def(module, param)
    else {
      return nil
    }
    return rack.value(found, def)
  }

  // MARK: - Drawing

  /// The rack, onto `canvas`, whose transform takes points to its pixels: the ground, the rack
  /// scaled into its space, then the header over it.
  public func draw(on canvas: Canvas) {
    rack.tick()
    let stage = stage
    scroll = stage.scroll
    canvas.fill = Theme.ground
    canvas.fillRect(0, 0, size.x, size.y)
    canvas.save()
    canvas.clip(stage.area.x, stage.area.y, stage.area.width, stage.area.height)
    canvas.translate(stage.origin.x, stage.origin.y)
    canvas.scale(stage.scale, stage.scale)
    let hovered = hover.flatMap { stage.area.contains($0) ? stage.design($0) : nil }
    for face in stage.faces { drawFace(face, hovered: hovered, on: canvas) }
    canvas.restore()
    drawHeader(stage, on: canvas)
  }

  private func drawHeader(_ stage: RackStage, on canvas: Canvas) {
    Draw.panel(stage.header, on: canvas)
    let baseline = stage.header.y + stage.header.height / 2 + 5
    canvas.save()
    canvas.clip(stage.title.x, stage.title.y, stage.title.width, stage.title.height)
    canvas.align = .left
    canvas.font = Theme.mono(8.5, weight: 500)
    canvas.fill = Theme.dim
    canvas.fillText("RACK", stage.title.x, baseline - 9)
    canvas.font = Theme.mono(13, weight: 600)
    canvas.fill = Theme.ink
    canvas.fillText(rack.name, stage.title.x, baseline + 6)
    canvas.restore()
    for chip in stage.chips {
      let down = pressed?.target == chip.target && hover.map(chip.frame.contains) == true
      Draw.chip(
        chip.frame, label: chip.label, isOn: chip.isOn, hovered: hover.map(chip.frame.contains) ?? false,
        down: down, on: canvas)
    }
    // The tempo, as a number dragged.
    let dragging = turning?.target == .tempo
    let tempo = stage.tempo
    if dragging || hover.map(tempo.contains) == true {
      canvas.fill = Theme.white(0.07)
      canvas.fillRoundedRect(tempo.x, tempo.y, tempo.width, tempo.height, radius: 6)
    }
    canvas.align = .left
    canvas.font = Theme.mono(8.5, weight: 500)
    canvas.fill = Theme.dim
    canvas.fillText("BPM", tempo.x + 7, baseline - 1)
    canvas.align = .right
    canvas.font = Theme.mono(14, weight: 600)
    canvas.fill = dragging ? Theme.nine : Theme.ink.faded(0.9)
    canvas.fillText(
      "\(Int((dragging ? turning!.value : rack.tempo).rounded()))", tempo.maxX - 7, baseline + 1)
    canvas.align = .left
    canvas.font = Theme.mono(10)
    canvas.fill = Theme.dim
    canvas.fillText("keys C\(2 + octave)", stage.keys.x, baseline)
  }

  /// A module's front: its panel, lit when selected; its title; and its controls.
  private func drawFace(_ face: RackStage.Face, hovered: SIMD2<Float>?, on canvas: Canvas) {
    let frame = face.frame
    let selected = rack.selection.contains(face.module.id)
    let over = hovered.map(frame.contains) ?? false
    guard let def = face.def else {
      canvas.stroke = Theme.edge
      canvas.lineWidth = 1
      canvas.strokeRoundedRect(frame.x, frame.y, frame.width, frame.height, radius: 12)
      canvas.align = .center
      canvas.font = Theme.mono(10)
      canvas.fill = Theme.dim
      canvas.fillText(
        "\(face.module.type) — not in this build yet", frame.x + frame.width / 2,
        frame.y + frame.height / 2 + 4)
      return
    }
    let dim: Float = face.module.bypassed ? 0.55 : 1
    canvas.fill = Colour(0x1e1638, alpha: 0.9 * dim)
    canvas.fillRoundedRect(
      frame.x, frame.y, frame.width, frame.height, radius: 12, foot: Colour(0x100b21, alpha: 0.9 * dim))
    canvas.stroke = selected ? Theme.nine : Theme.white(over ? 0.16 : 0.09)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(frame.x, frame.y, frame.width, frame.height, radius: 12)

    canvas.save()
    canvas.clip(frame.x, frame.y, frame.width, frame.height)
    // The title: the name, and what its jacks add up to at the right, over a hairline.
    let title = face.title
    let baseline = title.y + title.height / 2 + 4
    canvas.align = .left
    canvas.font = Theme.mono(11, weight: 600)
    canvas.fill = Theme.ink.faded(dim)
    canvas.fillText(def.name.uppercased(), title.x, baseline)
    canvas.align = .right
    canvas.font = Theme.mono(9)
    canvas.fill = Theme.dim.faded(0.8 * dim)
    canvas.fillText(RackLayout.portSummary(def), title.maxX, baseline)
    canvas.fill = Theme.edge
    canvas.fillRect(title.x, title.maxY + 4, title.width, 1)
    let tint = Self.tint(ModuleFace.byType[def.type]?.group)
    for control in face.controls {
      drawControl(control, module: face.module, tint: tint, hovered: hovered, on: canvas)
    }
    canvas.restore()
    if face.module.bypassed {
      let tag = Rect(frame.maxX - 76, frame.y - 7, 64, 14)
      canvas.fill = Theme.ground
      canvas.fillRoundedRect(tag.x, tag.y, tag.width, tag.height, radius: 7)
      canvas.stroke = Theme.three.faded(0.5)
      canvas.strokeRoundedRect(tag.x, tag.y, tag.width, tag.height, radius: 7)
      canvas.align = .center
      canvas.font = Theme.mono(8.5)
      canvas.fill = Theme.three
      canvas.fillText("bypassed", tag.x + tag.width / 2, tag.y + 10)
    }
  }

  private func drawControl(
    _ control: RackStage.Control, module: PatchModule, tint: Colour, hovered: SIMD2<Float>?, on canvas: Canvas
  ) {
    let def = control.param
    let target = RackTarget.knob(module: module.id, param: def.id)
    let active = turning?.target == target
    let value = active ? turning!.value : rack.value(module, def)
    switch control.kind {
    case .knob(let dial):
      let span = def.max - def.min
      Draw.knob(
        dial, value: span == 0 ? 0 : (value - def.min) / span, label: def.name,
        text: RackDisplay.value(def, value), tint: tint, active: active,
        hovered: hovered.map(control.cell.contains) ?? false, on: canvas)
    case .options(let buttons):
      let labels = ModuleFace.byType[module.type]?.labels[def.id]
      for (index, button) in buttons.enumerated() {
        let on = Int(value.rounded()) == Int(def.min) + index
        canvas.fill = on ? tint : Theme.white(hovered.map(button.contains) == true ? 0.1 : 0.05)
        canvas.fillRoundedRect(button.x, button.y, button.width, button.height, radius: 4)
        canvas.align = .center
        canvas.font = Theme.mono(9, weight: on ? 600 : 400)
        canvas.fill = on ? Theme.ground : Theme.ink.faded(0.75)
        canvas.fillText(
          Self.label(index, def, labels), button.x + button.width / 2, button.y + button.height - 3.5)
      }
      name(def, in: control.cell, on: canvas)
    case .stepper(let shown, let down, let up):
      let labels = ModuleFace.byType[module.type]?.labels[def.id]
      let index = Int(value.rounded()) - Int(def.min)
      canvas.align = .center
      canvas.font = Theme.mono(9.5, weight: 600)
      canvas.fill = Theme.ink
      canvas.fillText(Self.label(index, def, labels), shown.x + shown.width / 2, shown.y + 11)
      for (button, label) in [(down, "‹"), (up, "›")] {
        Draw.chip(
          button, label: label, isOn: false, hovered: hovered.map(button.contains) ?? false, down: false,
          tint: tint, size: 10, on: canvas)
      }
      name(def, in: control.cell, on: canvas)
    }
    // A Combinator drives it: marked rather than disabled, as the reference marks it.
    if rack.isRouted(module.id, def.id) {
      canvas.fill = Theme.three
      canvas.fillEllipse(control.cell.maxX - 11, control.cell.y + 2, 5, 5)
    }
  }

  private func name(_ def: ParamDef, in cell: Rect, on canvas: Canvas) {
    canvas.align = .center
    canvas.font = Theme.mono(8.5, weight: 500)
    canvas.fill = Theme.dim
    canvas.fillText(def.name.uppercased(), cell.x + cell.width / 2, cell.y + 57)
  }

  /// A choice's words for its `index`th value, or the number it is.
  static func label(_ index: Int, _ def: ParamDef, _ labels: [String]?) -> String {
    labels.flatMap { index >= 0 && index < $0.count ? $0[index] : nil } ?? String(Int(def.min) + index)
  }

  /// A module's colour, by what it is for, as the Mac's faces have it.
  static func tint(_ group: String?) -> Colour {
    switch group {
    case "Sources", "Sequencing": Theme.three
    case "Filters", "Shaping", "Mixing": Theme.eight
    default: Theme.nine
    }
  }
}
