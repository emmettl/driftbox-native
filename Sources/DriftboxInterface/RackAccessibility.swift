import DriftboxRack
import DriftboxRackSession
import DriftboxShell

/// The rack as a screen reader is told it: the header's transport, tempo and Add; each module as a
/// group of its knobs, choices, buttons and numbers, each named as its face names it and set to what
/// its face says; and, turned round, the cables between them. What a screen reader asks of one is
/// done as a hand would do it, each as one step of undo.
///
/// Each control's id lasts from one frame to the next: a module's by its id in the patch, and a
/// control on it by the param it turns or its place on the face.
extension RackInterface {
  /// What is on screen, as the window hands it to the platform's accessibility.
  public var accessibility: AccessibilityNode { described().node }

  /// What a screen reader asked, done as a hand would do it; false for a control there is not, or
  /// one that does nothing now.
  @discardableResult
  public func perform(_ asked: AccessibilityAction) -> Bool {
    // Where the keyboard is, the window's business, not the controls'.
    if case .focus = asked { return false }
    guard let handle = described().handlers[asked.control] else { return false }
    handle(asked)
    return true
  }

  typealias Handler = (AccessibilityAction) -> Void

  /// The tree, and what each control does when asked.
  func described() -> (node: AccessibilityNode, handlers: [String: Handler]) {
    var handlers: [String: Handler] = [:]
    let stage = stage
    func frame(_ rect: Rect) -> SIMD4<Float> { SIMD4(rect.x, rect.y, rect.width, rect.height) }
    /// A rect in the rack's design space, where it is on the window.
    func placed(_ rect: Rect) -> SIMD4<Float> {
      let at = stage.origin + SIMD2(rect.x, rect.y) * stage.scale
      return SIMD4(at.x, at.y, rect.width * stage.scale, rect.height * stage.scale)
    }
    /// A target pressed as it is clicked, where a click on `rect` would land.
    func pressed(_ target: RackTarget, under rect: Rect) -> Handler {
      { [weak self] asked in
        if case .press = asked { self?.perform(target, at: SIMD2(rect.x, rect.maxY)) }
      }
    }

    var children: [AccessibilityNode] = []

    // The header: the patch, the transport, the tempo, the back and Add.
    var header: [AccessibilityNode] = []
    if stage.title.width > 0 {
      header.append(
        AccessibilityNode(
          id: "rack.name", role: .text, name: "Rack", value: rack.name, frame: frame(stage.title)))
    }
    for chip in stage.chips + (stage.keysChip.map { [$0] } ?? []) {
      let (id, name, role): (String, String, AccessibilityNode.Role)
      switch chip.target {
      case .run: (id, name, role) = ("rack.run", "Play", .toggle)
      case .flip: (id, name, role) = ("rack.flip", "Show the back", .toggle)
      case .add: (id, name, role) = ("rack.add", "Add a module", .button)
      case .patches: (id, name, role) = ("rack.patches", "Patches", .button)
      case .keys: (id, name, role) = ("rack.keys", "Show the keys", .button)
      default: continue
      }
      header.append(
        AccessibilityNode(
          id: id, role: role, name: name, value: chip.target == .patches ? rack.name : nil,
          isOn: role == .toggle ? chip.isOn : nil, frame: frame(chip.frame)))
      handlers[id] = pressed(chip.target, under: chip.frame)
    }
    header.append(
      AccessibilityNode(
        id: "rack.tempo", role: .slider, name: "Tempo", value: "\(Int(rack.tempo.rounded())) BPM",
        range: 20...300, current: rack.tempo, step: 1, frame: frame(stage.tempo)))
    handlers["rack.tempo"] = { [weak self] asked in
      guard let self else { return }
      let wanted: Double
      switch asked {
      case .set(_, let value): wanted = value
      case .increment: wanted = rack.tempo + 1
      case .decrement: wanted = rack.tempo - 1
      case .press, .focus: return
      }
      let next = max(20, min(300, wanted.rounded()))
      guard next != rack.tempo else { return }
      rack.setTempo(next)
      rack.endTurn()
    }
    if stage.keys.width > 0 {
      header.append(
        AccessibilityNode(
          id: "rack.octave", role: .text, name: "Keys", value: "C\(2 + octave)", frame: frame(stage.keys))
      )
    }
    children.append(
      AccessibilityNode(
        id: "header", role: .group, name: "Rack", frame: frame(stage.header), children: header))

    if rack.flipped {
      children.append(back(stage, placed: placed))
    } else {
      for face in stage.faces {
        children.append(module(face, stage: stage, placed: placed, handlers: &handlers))
      }
    }

    // A Combinator's routing, open beside the rack: for now, what it is and the way to close it.
    if let routing = stage.routing {
      let name = stage.faces.first { $0.module.id == routing.combi.id }.map(Self.name(of:)) ?? "Combinator"
      handlers["routing.close"] = pressed(.routing(.close), under: routing.close)
      children.append(
        AccessibilityNode(
          id: "routing", role: .group, name: "\(name)'s routing", frame: frame(routing.frame),
          children: [
            AccessibilityNode(
              id: "routing.close", role: .button, name: "Close the routing", frame: frame(routing.close)),
            AccessibilityNode(
              id: "routing.routes", role: .text,
              name: "\(rack.patch.modulation.count) routing\(rack.patch.modulation.count == 1 ? "" : "s")",
              value: "Not described to screen readers yet"),
          ]))
    }

    return (AccessibilityNode(id: "window", role: .group, name: "", children: children), handlers)
  }

  /// What a module's title calls it.
  static func name(of face: RackStage.Face) -> String {
    face.name ?? face.def?.name ?? face.module.type
  }

  // MARK: - A module

  /// A module's front: what it says of itself, a way to its menu, and every control on it, in the
  /// order they are read, across and down.
  func module(
    _ face: RackStage.Face, stage: RackStage, placed: (Rect) -> SIMD4<Float>,
    handlers: inout [String: Handler]
  ) -> AccessibilityNode {
    let id = face.module.id
    let prefix = "module.\(id)"
    let name = Self.name(of: face)
    guard let def = face.def else {
      return AccessibilityNode(
        id: prefix, role: .text, name: name, value: "Not in this build yet", frame: placed(face.frame))
    }
    var parts: [AccessibilityNode] = []

    // A face's own short name for a control, unless it is only the start of the param's, or another
    // control on the face has it too — the groovebox's strips' levels.
    let shared = Dictionary(face.controls.compactMap(\.name).map { ($0, 1) }, uniquingKeysWith: +)
    for control in face.controls {
      let full = Self.spoken(control.param)
      var said = control.name ?? full
      if full.lowercased().hasPrefix(said.lowercased()) || shared[said, default: 0] > 1 { said = full }
      parts.append(
        self.control(
          control, named: said, on: face.module, prefix: prefix, placed: placed, handlers: &handlers))
    }

    var counted: [String: Int] = [:]
    for (index, cell) in face.cells.enumerated() {
      counted[cell.slot, default: 0] += 1
      let cellId = "\(prefix).cell.\(index)"
      let text = cell.text?(cell.value) ?? (cell.isStep && cell.value == 0 ? "off" : String(cell.value))
      parts.append(
        AccessibilityNode(
          id: cellId, role: .slider, name: Self.name(of: cell, place: counted[cell.slot] ?? 1), value: text,
          range: Double(cell.range.lowerBound)...Double(cell.range.upperBound), current: Double(cell.value),
          step: 1, frame: placed(cell.frame)))
      handlers[cellId] = { [weak self] asked in
        guard let self, let cell = stage.faces.first(where: { $0.module.id == id })?.cells[safe: index] else {
          return
        }
        let wanted: Int
        switch asked {
        case .set(_, let value): wanted = Int(value.rounded())
        case .increment: wanted = cell.value + 1
        case .decrement: wanted = cell.value - 1
        case .focus: return
        case .press:
          // As a click on it does, where a click does anything.
          if let click = cell.click { press(click, on: id) }
          return
        }
        let next = min(cell.range.upperBound, max(cell.range.lowerBound, wanted))
        guard next != cell.value else { return }
        write(cell, next, on: id)
        rack.endTurn()
      }
    }

    for (index, button) in face.buttons.enumerated() {
      var (said, role, value) = Self.said(button, place: index, def: def)
      if case .tag = button.style, case .set(let param, _) = button.press,
        let choice = def.params.first(where: { $0.id == param })
      {
        // A tag says its choice by a letter: said in the choice's words.
        let labels = ModuleFace.byType[def.type]?.labels[param]
        value = Self.label(Int(rack.value(face.module, choice).rounded()) - Int(choice.min), choice, labels)
      }
      let buttonId = "\(prefix).button.\(index)"
      parts.append(
        AccessibilityNode(
          id: buttonId, role: role, name: said, value: value, isOn: role == .toggle ? button.isOn : nil,
          frame: placed(button.frame)))
      guard let press = button.press else { continue }
      handlers[buttonId] = { [weak self] asked in
        guard let self, case .press = asked else { return }
        if case .hold(let param) = press {
          // Held and let go of at once: a press of it, heard, and one step of undo.
          rack.turn(id, param, to: 1)
          rack.turn(id, param, to: 0)
          rack.endTurn()
        } else {
          pressModifiers = []
          self.press(press, on: id, from: button.frame)
        }
      }
    }

    // Read as a face is: row by row, down it, and across each row.
    parts.sort { a, b in
      let rowA = (a.frame.y / 6).rounded(.down)
      let rowB = (b.frame.y / 6).rounded(.down)
      return rowA != rowB ? rowA < rowB : a.frame.x < b.frame.x
    }

    let title = face.title
    let head = Rect(face.frame.x, face.frame.y, face.frame.width, title.maxY - face.frame.y)
    var first: [AccessibilityNode] = []
    if !face.words.isEmpty {
      first.append(
        AccessibilityNode(
          id: "\(prefix).words", role: .text, name: Self.words(face.words) ?? face.words,
          value: face.light.map { $0 ? "ready" : "empty" }, frame: placed(title)))
    }
    first.append(
      AccessibilityNode(
        id: "\(prefix).menu", role: .button, name: "\(name)'s menu", frame: placed(head)))
    handlers["\(prefix).menu"] = { [weak self] asked in
      guard let self, case .press = asked,
        let face = self.stage.faces.first(where: { $0.module.id == id })
      else { return }
      let at = SIMD2(
        self.stage.origin.x + face.title.x * self.stage.scale,
        self.stage.origin.y + face.title.maxY * self.stage.scale)
      if let menu = menu(at: at) { menuRequest = (menu, at) }
    }

    var says = name
    if face.module.bypassed { says += ", bypassed" }
    if rack.selection.contains(id) { says += ", selected" }
    return AccessibilityNode(
      id: prefix, role: .group, name: says, frame: placed(face.frame), children: first + parts)
  }

  /// A param's control as a slider: a knob over its range, a choice over its values, each set to
  /// what its face says; set, as one turn of it. A choice that only turns something on, a mute or
  /// a solo, is a toggle.
  func control(
    _ control: RackStage.Control, named name: String, on module: PatchModule, prefix: String,
    placed: (Rect) -> SIMD4<Float>,
    handlers: inout [String: Handler]
  ) -> AccessibilityNode {
    let def = control.param
    let id = "\(prefix).\(def.id)"
    let value = rack.value(module, def)
    let routed = rack.isRouted(module.id, def.id) ? "driven by a Combinator" : nil
    let moduleId = module.id
    let words: String
    let notch: Double
    switch control.kind {
    case .knob:
      words = control.display?(value) ?? RackDisplay.value(def, value)
      notch = control.whole ? 1 : (def.max - def.min) / 50
    case .options, .stepper:
      let labels = control.labels ?? ModuleFace.byType[module.type]?.labels[def.id]
      if Self.switches(def, labels) {
        handlers[id] = { [weak self] asked in
          guard let self, case .press = asked, let now = self.value(moduleId, def.id) else { return }
          rack.set(moduleId, def.id, to: now >= def.max ? def.min : def.max)
        }
        return AccessibilityNode(
          id: id, role: .toggle, name: name, value: routed, isOn: value >= def.max,
          frame: placed(control.cell))
      }
      words = Self.label(Int(value.rounded()) - Int(def.min), def, labels)
      notch = 1
    }
    let whole = control.whole || def.stepped
    handlers[id] = { [weak self] asked in
      guard let self, let now = self.value(moduleId, def.id) else { return }
      let wanted: Double
      switch asked {
      case .set(_, let value): wanted = value
      case .increment: wanted = now + notch
      case .decrement: wanted = now - notch
      case .press, .focus: return
      }
      let clamped = max(def.min, min(def.max, wanted))
      let next = whole ? RackDisplay.jsRound(clamped) : clamped
      guard next != now else { return }
      rack.set(moduleId, def.id, to: next)
    }
    return AccessibilityNode(
      id: id, role: .slider, name: name, value: words + (routed.map { ", \($0)" } ?? ""),
      range: def.min...def.max, current: value, step: notch, frame: placed(control.cell))
  }

  /// A param's name as it is said rather than printed on a panel: a short one by the param it
  /// names — the envelope's A, D, S and R, a delay's FB, a voice's Env amount — and its
  /// abbreviations whole.
  static func spoken(_ def: ParamDef) -> String {
    var name = def.name
    if name.count <= 3, def.id.count > name.count {
      // `envAmount`: its words, the first a capital.
      let words = def.id.reduce(into: "") { said, character in
        said += character.isUppercase ? " " + character.lowercased() : String(character)
      }
      name = words.prefix(1).uppercased() + words.dropFirst()
    }
    let words = name.split(separator: " ").enumerated().map { index, word in
      let whole = abbreviations[word.prefix(1).uppercased() + word.dropFirst()]
      return whole.map { index == 0 ? $0 : $0.lowercased() } ?? String(word)
    }
    return words.joined(separator: " ")
  }

  static let abbreviations = [
    "Res": "Resonance", "Freq": "Frequency", "FB": "Feedback", "Osc": "Oscillator", "Oct": "Octave",
    "Env": "Envelope", "Ch": "Channel", "Cab": "Cabinet", "Rev": "Reverse", "Vel": "Velocity",
  ]

  /// A choice of two that turns something on — a mute, a solo, a gate that is off or on: said as on
  /// or off.
  static func switches(_ def: ParamDef, _ labels: [String]?) -> Bool {
    guard def.stepped, def.max - def.min == 1 else { return false }
    return def.name.split(separator: " ").contains { $0 == "Mute" || $0 == "Solo" }
      || labels?.map { $0.lowercased() } == ["off", "on"]
  }

  // MARK: - The back

  /// The back, turned round to: each cable, from what to what, as words. Patching with a screen
  /// reader comes later.
  func back(_ stage: RackStage, placed: (Rect) -> SIMD4<Float>) -> AccessibilityNode {
    let names = Dictionary(
      stage.faces.map { ($0.module.id, Self.name(of: $0)) }, uniquingKeysWith: { a, _ in a })
    let modules = Dictionary(rack.patch.modules.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    func port(_ end: PortReference, out: Bool) -> String {
      let def = modules[end.module].flatMap { RackModules.registry[$0.type] }
      let ports = out ? def?.outlets : def?.inlets
      let port = ports?.first { $0.id == end.port }?.name ?? end.port
      return "\(names[end.module] ?? end.module) \(port)"
    }
    var cables = rack.patch.cables.enumerated().map { index, cable in
      AccessibilityNode(
        id: "cable.\(index)", role: .text, name: port(cable.from, out: true),
        value: "to \(port(cable.to, out: false))")
    }
    if cables.isEmpty {
      cables.append(AccessibilityNode(id: "cable.none", role: .text, name: "No cables"))
    }
    return AccessibilityNode(
      id: "back", role: .group, name: "The back, where the cables are",
      frame: SIMD4(stage.area.x, stage.area.y, stage.area.width, stage.area.height), children: cables)
  }

  // MARK: - Words

  /// A number on a face, named for what it is: a tracker lane's step, an arranger's section, a
  /// field's caption; `place` is which of its slot's it is, counting from one.
  static func name(of cell: RackStage.Cell, place: Int) -> String {
    let what = cell.name.split(separator: " ").dropFirst().joined(separator: " ")
    if let caption = cell.caption {
      // A field's caption, after what it edits: the start's bar, a zone's root.
      let said = words(caption) ?? caption
      return what.isEmpty ? said : "\(what) \(said.lowercased())"
    }
    let slot = cell.slot
    if slot.hasPrefix("lane"), let lane = Int(slot.dropFirst(4)) { return "Lane \(lane) step \(place)" }
    switch slot {
    case "patterns": return "Section \(cell.index + 1) pattern"
    case "repeats": return "Section \(cell.index + 1) bars"
    default:
      return cell.isStep ? "Step \(place)" : "\(what.isEmpty ? cell.name : what) \(place)"
    }
  }

  /// A button on a face, as a person would name it — by what it does where its label is a mark —
  /// whether it is on or off or just pressed, and anything more to say of it.
  static func said(_ button: RackStage.Button, place: Int, def: ModuleDef)
    -> (String, AccessibilityNode.Role, String?)
  {
    let label = words(button.label)
    func param(_ id: String) -> String { def.params.first { $0.id == id }?.name ?? id }
    switch button.press {
    case .startSong(let bar): return ("Play from bar \(bar + 1)", .button, nil)
    case .loopSong(let start, let bars): return ("Loop bars \(start + 1) to \(start + bars)", .toggle, nil)
    case .clearLoop: return ("Stop looping", .button, label)
    case .page(let page):
      switch button.label {
      case "‹": return ("Previous", .button, nil)
      case "›": return ("Next", .button, nil)
      default: return ("Page \(page + 1)", .toggle, nil)
      }
    case .choose:
      if case .prompt(let detail) = button.style { return (label ?? "Choose a file", .button, words(detail)) }
      return ("Choose a file", .button, label)
    case .sampleBars(let bars): return ("\(bars) bar\(bars == 1 ? "" : "s")", .toggle, nil)
    case .editSong: return ("Edit the song in the groovebox", .button, nil)
    case .routes: return ("Routing", .toggle, nil)
    case .plugin: return ("Choose a plug-in", .button, label)
    case .macros: return ("Map the macros", .button, nil)
    case .open: return ("Open the plug-in's window", .button, nil)
    case .learn(let id): return ("Learn a controller for \(param(id))", .toggle, nil)
    case .hold(let id): return (label ?? param(id), .button, nil)
    case .set, .data, nil: break
    }
    switch button.style {
    case .key: return (button.label, .toggle, nil)
    case .pulse: return (button.label == "D" ? "The note itself" : "Echo \(button.label)", .toggle, nil)
    case .voice(let lane, _): return ("Voice \(lane + 1)", .toggle, label)
    case .arpStep(let number, _): return ("Step \(number)", .toggle, label)
    case .slice: return ("Slice \(button.label)", .toggle, nil)
    case .zone(_, let note): return ("Zone \(note)", .toggle, nil)
    case .pad: return ("Button \(button.label)", .toggle, nil)
    case .tag:
      if case .set(let id, _) = button.press { return (param(id), .button, label) }
    default: break
    }
    // A choice's stepper, by what it steps.
    if case .set(let id, _) = button.press, ["‹", "›"].contains(button.label) {
      return ("\(button.label == "‹" ? "Previous" : "Next") \(param(id).lowercased())", .button, nil)
    }
    return (label ?? "Button \(place + 1)", button.press == nil ? .button : .toggle, nil)
  }

  /// A face's label in words a screen reader says as words: its capitals made a word's, and nil for
  /// one that is only marks.
  static func words(_ label: String) -> String? {
    // Swift's own: Android links only Foundation's essentials, which have no character sets.
    let trimmed = String(label.drop { $0.isWhitespace }.reversed().drop { $0.isWhitespace }.reversed())
    guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
    guard trimmed == trimmed.uppercased(), trimmed.contains(where: \.isLetter) else { return trimmed }
    return trimmed.prefix(1) + trimmed.dropFirst().lowercased()
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
