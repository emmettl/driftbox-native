import DriftboxRack
import DriftboxRackSession
import DriftboxShell

/// The rack's back and a Combinator's routing as a screen reader is told them, and patched from
/// one. A cable is taken from one jack and plugged into another, as a hand drags it: press a jack
/// to take a cable from it, and another of the other kind to plug it in. Each inlet's trim is a
/// slider, and a cable in an inlet can be pulled out.
extension RackInterface {
  /// The back: word of a cable being held, then each module's jacks, each saying what it is
  /// patched to; each inlet's trim, and a way to pull its cable out.
  func back(
    _ stage: RackStage, placed: (Rect) -> SIMD4<Float>, handlers: inout [String: Handler]
  ) -> AccessibilityNode {
    let names = Dictionary(
      stage.faces.map { ($0.module.id, Self.name(of: $0)) }, uniquingKeysWith: { a, _ in a })
    let jacks = RackLayout.jacks(stage.placements)
    func said(_ module: String, _ port: String, _ kind: RackLayout.Jack.Kind) -> String {
      let jack = RackLayout.jack(in: jacks, module: module, port: port, kind: kind)
      return "\(names[module] ?? module) \(jack?.name ?? port)"
    }
    func key(_ jack: RackLayout.Jack) -> String {
      "\(jack.module).\(jack.port).\(jack.kind == .inlet ? "in" : "out")"
    }
    // A held cable whose jack has gone, with its module, is held no longer.
    let held = picked.flatMap { picked in jacks.first { key($0) == key(picked) } }

    var children: [AccessibilityNode] = []
    if let held {
      children.append(
        AccessibilityNode(
          id: "back.held", role: .text,
          name: "Holding a cable from \(said(held.module, held.port, held.kind))",
          value: held.kind == .outlet ? "Press an inlet to plug it in" : "Press an outlet to plug it in"))
      children.append(AccessibilityNode(id: "back.drop", role: .button, name: "Put the cable down"))
      handlers["back.drop"] = { [weak self] asked in if case .press = asked { self?.picked = nil } }
    } else {
      children.append(
        AccessibilityNode(
          id: "back.help", role: .text, name: "Patching",
          value: "Press a jack to take a cable from it, and one of the other kind to plug it in"))
    }

    for placement in stage.placements {
      let module = placement.id
      var parts: [AccessibilityNode] = []
      for jack in jacks where jack.module == module {
        let id = "jack.\(key(jack))"
        let at = SIMD2(Float(jack.x), Float(jack.y))
        var words: [String] = [jack.kind == .inlet ? "inlet" : "outlet"]
        if jack.kind == .outlet {
          let to = rack.patch.cables.filter { $0.from.module == module && $0.from.port == jack.port }
          words.append(
            to.isEmpty
              ? "not patched"
              : "to " + to.map { said($0.to.module, $0.to.port, .inlet) }.joined(separator: ", "))
        } else {
          let from = rack.patch.cables.first { $0.to.module == module && $0.to.port == jack.port }
          words.append(from.map { "from " + said($0.from.module, $0.from.port, .outlet) } ?? "not patched")
        }
        if held == jack { words.append("its cable held") }
        parts.append(
          AccessibilityNode(
            id: id, role: .button, name: jack.name, value: words.joined(separator: ", "),
            frame: placed(Rect(at.x - 8, at.y - 8, 16, 16))))
        handlers[id] = { [weak self] asked in
          guard let self, case .press = asked else { return }
          plug(jack)
        }

        guard jack.kind == .inlet else { continue }
        let trim = rack.trim(module, jack.port)
        let trimId = "trim.\(module).\(jack.port)"
        let pot = Self.pot(jack)
        parts.append(
          AccessibilityNode(
            id: trimId, role: .slider, name: "\(jack.name) trim", value: RackDisplay.trim(trim),
            range: -1...1, current: trim, step: 0.05, frame: placed(Rect(pot.x - 10, pot.y - 10, 20, 20))))
        handlers[trimId] = { [weak self] asked in
          guard let self else { return }
          let wanted: Double
          switch asked {
          case .set(_, let value): wanted = value
          case .increment: wanted = trim + 0.05
          case .decrement: wanted = trim - 0.05
          case .press, .focus: return
          }
          rack.setTrim(module, jack.port, to: RackDisplay.trimStep(wanted))
          rack.endTurn()
        }
        if let cable = rack.patch.cables.first(where: { $0.to.module == module && $0.to.port == jack.port }) {
          let unplugId = "unplug.\(module).\(jack.port)"
          let cross = Self.unplug(at)
          parts.append(
            AccessibilityNode(
              id: unplugId, role: .button, name: "Pull out the cable in \(jack.name)",
              frame: placed(Rect(cross.x - 8, cross.y - 8, 16, 16))))
          handlers[unplugId] = { [weak self] asked in
            if case .press = asked { self?.rack.disconnect(cable) }
          }
        }
      }
      children.append(
        AccessibilityNode(
          id: "bay.\(module)", role: .group, name: names[module] ?? module,
          frame: placed(
            Rect(Float(placement.x), Float(placement.y), Float(placement.width), Float(placement.height))),
          children: parts))
    }
    return AccessibilityNode(
      id: "back", role: .group, name: "The back, where the cables are",
      frame: SIMD4(stage.area.x, stage.area.y, stage.area.width, stage.area.height), children: children)
  }

  /// A jack pressed by a screen reader: its cable taken up, or the one held plugged into it, from
  /// an outlet to an inlet as a drag would; the held one pressed again is put down.
  func plug(_ jack: RackLayout.Jack) {
    guard let held = picked, held != jack else {
      picked = picked == jack ? nil : jack
      return
    }
    guard held.kind != jack.kind else {
      picked = jack
      return
    }
    let (outlet, inlet) = held.kind == .outlet ? (held, jack) : (jack, held)
    rack.connect(PortReference(outlet.module, outlet.port), PortReference(inlet.module, inlet.port))
    picked = nil
  }

  // MARK: - The routing

  /// A Combinator's routing: each routing's source, target and knob, as buttons that offer the
  /// menus a click does, and its two ends as sliders over the knob's range; and the ways to add
  /// one, remove one, and close it.
  func routing(
    _ routing: RackStage.Routing, stage: RackStage, handlers: inout [String: Handler]
  ) -> AccessibilityNode {
    func frame(_ rect: Rect) -> SIMD4<Float> { SIMD4(rect.x, rect.y, rect.width, rect.height) }
    func pressed(_ part: RoutingPart, under rect: Rect) -> Handler {
      { [weak self] asked in
        if case .press = asked { self?.perform(part, at: SIMD2(rect.x, rect.maxY)) }
      }
    }
    let names = Dictionary(
      stage.faces.map { ($0.module.id, Self.name(of: $0)) }, uniquingKeysWith: { a, _ in a })
    let combi = names[routing.combi.id] ?? "Combinator"
    var children: [AccessibilityNode] = [
      AccessibilityNode(
        id: "routing.close", role: .button, name: "Close the routing", frame: frame(routing.close))
    ]
    handlers["routing.close"] = pressed(.close, under: routing.close)

    for row in routing.rows {
      let index = row.index
      guard rack.patch.modulation.indices.contains(index) else { continue }
      let route = rack.patch.modulation[index]
      let sourceType = rack.patch.modules.first { $0.id == route.from.module }?.type ?? "combi"
      let source =
        RackSession.routable(sourceType).first { $0.id == route.from.port }?.name ?? route.from.port
      let targetType = rack.patch.modules.first { $0.id == route.to.module }?.type
      let knob =
        targetType.flatMap { RackSession.routable($0).first { $0.id == route.to.port } }.map(Self.spoken)
        ?? route.to.port
      let module = names[route.to.module] ?? route.to.module
      let prefix = "route.\(index)"
      var parts: [AccessibilityNode] = []
      for (part, name, value, rect) in [
        (RoutingPart.source(index), "Source", source, row.source),
        (.module(index), "Module", module, row.module),
        (.knob(index), "Knob", knob, row.knob),
      ] {
        let id = "\(prefix).\(name.lowercased())"
        parts.append(AccessibilityNode(id: id, role: .button, name: name, value: value, frame: frame(rect)))
        handlers[id] = pressed(part, under: rect)
      }
      for (isMax, name, rect) in [(false, "Lowest", row.min), (true, "Highest", row.max)] {
        guard let (value, def) = routeEnd(index, isMax: isMax) else { continue }
        let id = "\(prefix).\(isMax ? "max" : "min")"
        let own = (isMax ? route.max : route.min) == nil
        let span = def.max - def.min
        let notch = def.stepped ? 1 : span / 50
        parts.append(
          AccessibilityNode(
            id: id, role: .slider, name: name, value: Self.round(value) + (own ? ", the knob's own" : ""),
            range: def.min...def.max, current: value, step: notch, frame: frame(rect)))
        handlers[id] = { [weak self] asked in
          guard let self else { return }
          let wanted: Double
          switch asked {
          case .set(_, let set): wanted = set
          case .increment: wanted = value + notch
          case .decrement: wanted = value - notch
          case .press, .focus: return
          }
          var next = max(def.min, min(def.max, wanted))
          if def.stepped { next = next.rounded() }
          rack.setRoute(index) { route in
            if isMax { route.max = next } else { route.min = next }
          }
        }
      }
      parts.append(
        AccessibilityNode(
          id: "\(prefix).remove", role: .button, name: "Remove this routing", frame: frame(row.remove)))
      handlers["\(prefix).remove"] = pressed(.remove(index), under: row.remove)
      children.append(
        AccessibilityNode(
          id: prefix, role: .group, name: "Routing \(row.number): \(source) to \(module) \(knob)",
          frame: frame(row.frame), children: parts))
    }
    if routing.hidden > 0 {
      children.append(
        AccessibilityNode(
          id: "routing.hidden", role: .text,
          name: "\(routing.hidden) more routing\(routing.hidden == 1 ? "" : "s")",
          value: "Not shown: the window is too short for them"))
    }
    children.append(
      AccessibilityNode(id: "routing.add", role: .button, name: "Add a routing", frame: frame(routing.add)))
    handlers["routing.add"] = pressed(.add, under: routing.add)
    let name = "\(combi)'s routing"
    return AccessibilityNode(
      id: "routing", role: .group, name: name, frame: frame(routing.frame), children: children)
  }
}
