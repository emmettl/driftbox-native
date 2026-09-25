import DriftboxCanvas
import DriftboxRack
import DriftboxRackSession
import DriftboxShell

/// A Combinator's routing, to edit, beside the rack as the Mac's `RoutingInspector` is: which
/// control moves which knob, and between what. Read and typed rather than dragged, and open while a
/// rotary turns, so the value each routing is putting on its target can be watched moving. Source,
/// target, min and max, and no more: anything else is a cable and an Offset.
extension RackStage {
  /// Where the routing and each of its parts are, in points on the window.
  public struct Routing {
    public static let width: Float = 300
    static let rowHeight: Float = 114

    /// One routing: where it is among the patch's routings, which is what edits it, and among
    /// this Combinator's; and where its parts are.
    public struct Row {
      public var index: Int
      public var number: Int
      public var frame: Rect
      public var source: Rect
      public var module: Rect
      public var knob: Rect
      public var min: Rect
      public var max: Rect
      public var remove: Rect
    }

    public var combi: PatchModule
    public var frame: Rect
    public var close: Rect
    public var add: Rect
    public var rows: [Row]
    /// Routings there was no room for.
    public var hidden: Int

    @MainActor
    init(combi: PatchModule, rack: RackSession, frame: Rect) {
      self.combi = combi
      self.frame = frame
      let x = frame.x + 14
      let width = max(0, frame.width - 28)
      close = Rect(frame.maxX - 14 - 18, frame.y + 10, 18, 18)
      let routes = rack.patch.modulation.indices.filter { rack.patch.modulation[$0].from.module == combi.id }
      // Nothing routed, and a word on what a routing is in its place.
      var y = frame.y + 40 + (routes.isEmpty ? 56 : 0)
      rows = []
      hidden = 0
      for (number, index) in routes.enumerated() {
        guard y + Self.rowHeight + 70 <= frame.maxY else {
          hidden = routes.count - number
          break
        }
        let row = Rect(x, y, width, Self.rowHeight)
        let inner = row.x + 30
        let source = Rect(inner, row.y + 10, 92, 20)
        let remove = Rect(row.maxX - 10 - 18, row.y + 11, 18, 18)
        rows.append(
          Row(
            index: index, number: number + 1, frame: row, source: source,
            module: Rect(source.maxX + 22, row.y + 10, max(40, remove.x - 8 - source.maxX - 22), 20),
            knob: Rect(inner, row.y + 40, min(180, row.maxX - 10 - inner), 20),
            min: Rect(inner, row.y + 82, 76, 20), max: Rect(inner + 86, row.y + 82, 76, 20), remove: remove))
        y += Self.rowHeight + 10
      }
      add = Rect(x, y, 112, 20)
    }

    func part(at point: SIMD2<Float>) -> RoutingPart? {
      guard frame.contains(point) else { return nil }
      if close.contains(point) { return .close }
      if add.contains(point) { return .add }
      for row in rows {
        if row.remove.contains(point) { return .remove(row.index) }
        if row.source.contains(point) { return .source(row.index) }
        if row.module.contains(point) { return .module(row.index) }
        if row.knob.contains(point) { return .knob(row.index) }
        if row.min.contains(point) { return .min(row.index) }
        if row.max.contains(point) { return .max(row.index) }
      }
      return nil
    }
  }
}

extension RackInterface {
  /// Whether keys are being typed into the rack, as one end of a routing: the window lets them
  /// through as text rather than shortcuts.
  public var takesText: Bool { typing != nil }

  /// A number short enough to read at a glance: a cutoff whole, a resonance to hundredths, as the
  /// reference rounds a routing's.
  static func round(_ value: Double) -> String {
    let rounded = abs(value) >= 100 ? RackDisplay.jsRound(value) : RackDisplay.jsRound(value * 100) / 100
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
  }

  /// A press on the routing: a menu to choose from, an end to type, or a routing added, removed
  /// or the routing closed.
  func perform(_ part: RoutingPart, at point: SIMD2<Float>) {
    guard let combi = rack.editingRoutes else { return }
    switch part {
    case .close:
      rack.editRoutes(nil)
    case .add:
      rack.addRoute(combi)
    case .remove(let index):
      rack.removeRoute(index)
    case .source(let index):
      menuRequest = (sourceMenu(index), point)
    case .module(let index):
      menuRequest = (moduleMenu(index), point)
    case .knob(let index):
      menuRequest = (knobMenu(index), point)
    case .min(let index), .max(let index):
      let isMax = if case .max = part { true } else { false }
      let route = rack.patch.modulation[index]
      let value = isMax ? route.max : route.min
      typing = (index, isMax, value.map(Self.round) ?? "")
    }
  }

  /// A menu begun afresh: nothing it offers yet.
  private func startMenu() {
    menuActions = [:]
    menuDisabled = []
    menuChecked = []
  }

  /// The Combinator's controls a routing can come from.
  func sourceMenu(_ index: Int) -> Menu {
    startMenu()
    let route = rack.patch.modulation[index]
    let type = rack.patch.modules.first { $0.id == route.from.module }?.type ?? "combi"
    return Menu(
      "Source",
      RackSession.routable(type).map { param in
        item(param.name, "route.source.\(param.id)", checked: param.id == route.from.port) {
          self.rack.setRoute(index) { $0.from = PortReference(route.from.module, param.id) }
        }
      })
  }

  /// The modules with a knob to drive.
  func moduleMenu(_ index: Int) -> Menu {
    startMenu()
    let route = rack.patch.modulation[index]
    return Menu(
      "Module",
      rack.patch.modules.filter { !RackSession.routable($0.type).isEmpty }.map { module in
        item(module.id, "route.module.\(module.id)", checked: module.id == route.to.module) {
          self.rack.setRoute(index) { $0.to = PortReference(module.id, $0.to.port) }
        }
      })
  }

  /// The knobs of the routing's target.
  func knobMenu(_ index: Int) -> Menu {
    startMenu()
    let route = rack.patch.modulation[index]
    let type = rack.patch.modules.first { $0.id == route.to.module }?.type
    return Menu(
      "Knob",
      (type.map(RackSession.routable) ?? []).map { param in
        item(param.name, "route.knob.\(param.id)", checked: param.id == route.to.port) {
          self.rack.setRoute(index) { $0.to = PortReference($0.to.module, param.id) }
        }
      })
  }

  /// A key into the end being typed: a digit, a point or a sign; Backspace; Return to set it —
  /// blank is the target's own limit — and Escape to leave it as it was. Every key is the field's
  /// while it is typed into.
  func type(_ event: KeyEvent) -> Bool {
    guard var typed = typing else { return false }
    guard event.isDown else { return true }
    switch event.key {
    case .return: finishTyping()
    case .escape: typing = nil
    case .backspace:
      if !typed.text.isEmpty { typed.text.removeLast() }
      typing = typed
    case .character(let character) where character.isNumber || character == "." || character == "-":
      typed.text.append(character)
      typing = typed
    default:
      break
    }
    return true
  }

  /// The end being typed, set: to what is typed, or to the target's own limit when that is blank;
  /// left as it was when what is typed is not a number.
  func finishTyping() {
    guard let typed = typing else { return }
    typing = nil
    // Trimmed by hand: `CharacterSet` is the old Foundation's on Android.
    let text = String(
      typed.text.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
    let value: Double?
    if text.isEmpty {
      value = nil
    } else if let number = Double(text) {
      value = number
    } else {
      return
    }
    guard rack.patch.modulation.indices.contains(typed.index) else { return }
    rack.setRoute(typed.index) { route in
      if typed.isMax { route.max = value } else { route.min = value }
    }
  }

  // MARK: Drawing

  /// The routing, over the right of the window, in its points.
  func drawRouting(_ routing: RackStage.Routing, hovered: SIMD2<Float>?, on canvas: Canvas) {
    let frame = routing.frame
    canvas.fill = Theme.ground
    canvas.fillRect(frame.x, frame.y, frame.width, frame.height)
    canvas.fill = Theme.edge
    canvas.fillRect(frame.x, frame.y, 1, frame.height)
    let x = frame.x + 14
    canvas.align = .left
    canvas.font = Theme.mono(11, weight: 600)
    canvas.fill = Theme.ink
    canvas.fillText("ROUTING", x, frame.y + 24)
    let after = x + canvas.measure("ROUTING") + 8
    canvas.font = Theme.mono(9)
    canvas.fill = Theme.dim
    canvas.fillText(routing.combi.id, after, frame.y + 24)
    cross(routing.close, lit: hovered.map(routing.close.contains) ?? false, on: canvas)

    let routes = rack.patch.modulation
    if routing.rows.isEmpty && routing.hidden == 0 {
      canvas.font = Theme.mono(9)
      canvas.fill = Theme.dim
      wrap(
        "Nothing routed yet. A routing points one rotary or button at one knob anywhere in the rack; "
          + "the knob then moves when the rotary does, between the two ends set here.",
        x: x, y: frame.y + 52, width: frame.width - 28, on: canvas)
    }
    for row in routing.rows where routes.indices.contains(row.index) {
      drawRoute(row, routes[row.index], hovered: hovered, on: canvas)
    }
    let y = routing.add.y
    if routing.hidden > 0 {
      canvas.align = .left
      canvas.font = Theme.mono(9)
      canvas.fill = Theme.dim
      canvas.fillText("and \(routing.hidden) more routings", x, y - 2)

    }
    let enabled = rack.defaultTarget(routing.combi.id) != nil
    Draw.chip(
      Rect(x, y, routing.add.width, routing.add.height), label: "Add Routing", isOn: enabled,
      hovered: enabled && (hovered.map(routing.add.contains) ?? false), down: false, tint: Theme.nine,
      size: 9,
      on: canvas)
    canvas.align = .left
    canvas.font = Theme.mono(8.5)
    canvas.fill = Theme.dim
    wrap(
      enabled
        ? "4 rotaries and 4 buttons · a later routing wins a shared target"
        : "Nothing else in the rack has a knob to drive: add a module first",
      x: x, y: y + 36, width: frame.width - 28, on: canvas)
  }

  private func drawRoute(
    _ row: RackStage.Routing.Row, _ route: ModRoute, hovered: SIMD2<Float>?, on canvas: Canvas
  ) {
    let r = row.frame
    canvas.fill = Theme.panel
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 8)
    canvas.stroke = Theme.edge
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 8)
    canvas.align = .left
    canvas.font = Theme.mono(9, weight: 600)
    canvas.fill = Theme.three
    canvas.fillText("\(row.number)", r.x + 10, row.source.midY + 3)

    let combi = rack.patch.modules.first { $0.id == route.from.module }
    let source = combi.flatMap { RackSession.routable($0.type).first { $0.id == route.from.port } }
    let target = rack.patch.modules.first { $0.id == route.to.module }
    let param = target.flatMap { RackSession.routable($0.type).first { $0.id == route.to.port } }
    picker(row.source, source?.name ?? route.from.port, hovered: hovered, on: canvas)
    canvas.align = .center
    canvas.font = Theme.mono(10)
    canvas.fill = Theme.dim
    canvas.fillText("→", row.source.maxX + 11, row.source.midY + 3.5)
    // A target this build cannot find is kept and shown, never quietly re-aimed.
    picker(
      row.module, target == nil ? "\(route.to.module) (not here)" : route.to.module, hovered: hovered,
      on: canvas)
    picker(row.knob, param?.name ?? "\(route.to.port) (unknown)", hovered: hovered, on: canvas)
    minus(row.remove, lit: hovered.map(row.remove.contains) ?? false, on: canvas)

    end("MIN", row.min, route.min, limit: param?.min, isMax: false, index: row.index, on: canvas)
    end("MAX", row.max, route.max, limit: param?.max, isMax: true, index: row.index, on: canvas)
    // What the routing is putting on its target now, by the arithmetic the sound gets.
    let now: String = {
      guard let param,
        let position = sourcePosition(rack.patch.modules, registry: RackModules.registry, from: route.from)
      else { return "—" }
      return Self.round(routeValue(route, position: position, param: param))
    }()
    canvas.align = .right
    canvas.font = Theme.mono(7.5)
    canvas.fill = Theme.dim
    canvas.fillText("NOW", r.maxX - 10, row.min.y - 4)
    canvas.font = Theme.mono(11, weight: 600)
    canvas.fill = Theme.nine
    canvas.fillText(now, r.maxX - 10, row.min.maxY - 5)
  }

  /// A menu's box: what is chosen in it, and a mark that it opens.
  private func picker(_ r: Rect, _ text: String, hovered: SIMD2<Float>?, on canvas: Canvas) {
    canvas.fill = Theme.white(hovered.map(r.contains) == true ? 0.1 : 0.05)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 4)
    canvas.stroke = Theme.edge
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 4)
    canvas.align = .left
    canvas.fill = Theme.ink
    canvas.fillText(
      Draw.fit(text, width: r.width - 22, size: 9, weight: 400, on: canvas), r.x + 6, r.midY + 3)
    canvas.align = .right
    canvas.font = Theme.mono(8)
    canvas.fill = Theme.dim
    canvas.fillText("▾", r.maxX - 5, r.midY + 3)
  }

  /// One end of a routing's range: typed into, or its value, or, blank, the target's own limit,
  /// faint, so a module that widens its range later is swept to its new end.
  private func end(
    _ label: String, _ r: Rect, _ value: Double?, limit: Double?, isMax: Bool, index: Int, on canvas: Canvas
  ) {
    canvas.align = .left
    canvas.font = Theme.mono(7.5)
    canvas.fill = Theme.dim
    canvas.fillText(label, r.x, r.y - 4)
    let typed = typing.flatMap { $0.index == index && $0.isMax == isMax ? $0.text : nil }
    canvas.fill = Colour(0x000000, alpha: 0.35)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 4)
    canvas.stroke = typed == nil ? Theme.edge : Theme.nine
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 4)
    canvas.font = Theme.mono(10)
    if let typed {
      canvas.fill = Theme.ink
      canvas.fillText(typed, r.x + 6, r.midY + 3.5)
      canvas.fill = Theme.nine
      canvas.fillRect(r.x + 6 + canvas.measure(typed) + 1, r.y + 4, 1, r.height - 8)
    } else if let value {
      canvas.fill = Theme.ink
      canvas.fillText(Self.round(value), r.x + 6, r.midY + 3.5)
    } else if let limit {
      canvas.fill = Theme.dim.faded(0.6)
      canvas.fillText(Self.round(limit), r.x + 6, r.midY + 3.5)
    }
  }

  private func cross(_ r: Rect, lit: Bool, on canvas: Canvas) {
    canvas.stroke = lit ? Theme.ink : Theme.dim
    canvas.lineWidth = 1.5
    let c = SIMD2(r.midX, r.midY)
    canvas.strokeLines([(c + SIMD2(-4, -4), c + SIMD2(4, 4)), (c + SIMD2(4, -4), c + SIMD2(-4, 4))])
  }

  private func minus(_ r: Rect, lit: Bool, on canvas: Canvas) {
    canvas.stroke = lit ? Theme.eight : Theme.dim
    canvas.lineWidth = 1.2
    canvas.strokeArc(r.midX, r.midY, radius: 7, from: -.pi, to: .pi)
    canvas.strokeLines([(SIMD2(r.midX - 3.5, r.midY), SIMD2(r.midX + 3.5, r.midY))])
  }

  /// `text` in lines no wider than `width`, broken between words, from the baseline `y`.
  private func wrap(_ text: String, x: Float, y: Float, width: Float, on canvas: Canvas) {
    canvas.align = .left
    var line = ""
    var baseline = y
    for word in text.split(separator: " ") {
      let next = line.isEmpty ? String(word) : line + " " + word
      if !line.isEmpty, canvas.measure(next) > width {
        canvas.fillText(line, x, baseline)
        baseline += 13
        line = String(word)
      } else {
        line = next
      }
    }
    if !line.isEmpty { canvas.fillText(line, x, baseline) }
  }
}
