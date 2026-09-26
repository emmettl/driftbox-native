import DriftboxCanvas
import DriftboxRack
import DriftboxRackSession
import DriftboxShell

#if os(Android)
  // Its dates from FoundationEssentials, and C's maths from Android's own: the old Foundation's
  // `CGPoint` would be as much in sight as the rack's, which stands in for it there.
  import Android
  import FoundationEssentials
#else
  import Foundation
#endif

/// What a press on the back of the rack is doing.
enum BackGesture {
  /// Drawing a cable out of a jack, to drop on another.
  case patching(from: RackLayout.Jack)
  /// Turning an inlet's trim pot: from where on the window the press was, and what it read then.
  case trimming(RackLayout.Jack, fromY: Float, from: Double)
  /// Carrying a module to another place in the rack, held where it was grabbed.
  case moving(id: String, grab: SIMD2<Float>)
}

/// The back of the rack, as the Mac's `BackPanel` draws it: every module's bay with its jacks, inlets
/// down the left in teal and outlets down the right in amber, and the cables hanging between them,
/// swinging as the rack turns. Drag from a jack to a jack to patch — from either end, and it snaps —
/// click a cable's belly or the × by its inlet to pull it out; drag a bay to move its module. Beside
/// every inlet is a trim pot, dragged up and down, and pressed twice back to unity.
extension RackInterface {
  static let bay = Theme.white(0.02)
  static let jackFill = Colour(0x1b1430)
  static let hole = Colour(0x05030b)
  static let potFill = Colour(0x171026)
  static let lit = Colour(0x2a1f4a)
  static let cableColours = [Theme.nine, Theme.three, Theme.eight]

  /// Where an inlet's trim pot sits: to the right of its name, as the reference places it.
  public static func pot(_ jack: RackLayout.Jack) -> SIMD2<Float> { SIMD2(Float(jack.x) + 84, Float(jack.y)) }

  /// Where the × that pulls a cable out of its inlet sits.
  public static func unplug(_ inlet: SIMD2<Float>) -> SIMD2<Float> { SIMD2(inlet.x - 18, inlet.y) }

  // MARK: Where things are

  /// The placements as they are drawn: with a module being carried where the pointer has it.
  func placements(_ stage: RackStage) -> [RackLayout.Placement] {
    guard case .moving(let id, let grab) = back, let pointer = backPointer else { return stage.placements }
    return stage.placements.map { placement in
      guard placement.id == id else { return placement }
      var moved = placement
      moved.x = Double(pointer.x - grab.x)
      moved.y = Double(pointer.y - grab.y)
      return moved
    }
  }

  /// A cable's two ends, from its outlet to its inlet.
  func ends(_ cable: PatchCable, in jacks: [RackLayout.Jack]) -> (CGPoint, CGPoint)? {
    guard
      let from = RackLayout.jack(in: jacks, module: cable.from.module, port: cable.from.port, kind: .outlet),
      let to = RackLayout.jack(in: jacks, module: cable.to.module, port: cable.to.port, kind: .inlet)
    else { return nil }
    return (from.point, to.point)
  }

  /// How far a cable has swung since the rack turned round.
  func angle(_ cable: PatchCable, _ from: CGPoint, _ to: CGPoint, at now: Date = Date()) -> Double {
    guard let flipped = rack.flippedAt else { return 0 }
    let elapsed = now.timeIntervalSince(flipped) * 1000
    return Cable.swing(
      elapsed, from, to, direction: rack.flipped ? 1 : -1, seed: Cable.seed(RackSession.key(cable)))
  }

  static func distance(_ a: SIMD2<Float>, _ b: CGPoint) -> Float {
    let d = a - SIMD2(Float(b.x), Float(b.y))
    return (d * d).sum().squareRoot()
  }

  static func point(_ p: SIMD2<Float>) -> CGPoint { CGPoint(x: Double(p.x), y: Double(p.y)) }

  func potUnder(_ at: SIMD2<Float>, jacks: [RackLayout.Jack]) -> RackLayout.Jack? {
    jacks.first { jack in
      guard jack.kind == .inlet else { return false }
      let d = at - Self.pot(jack)
      return (d * d).sum() < 10 * 10
    }
  }

  // MARK: The hand

  /// Whether a press on the back at `location` would take something a finger means to use: an
  /// unplug button, a trim pot, a jack, a cable's belly. Anywhere else, a finger pans the rack.
  func backTakes(at location: SIMD2<Float>, stage: RackStage) -> Bool {
    let at = stage.design(location)
    let jacks = RackLayout.jacks(stage.placements)
    for cable in rack.patch.cables {
      guard let (from, to) = ends(cable, in: jacks) else { continue }
      if Self.distance(at, Self.point(Self.unplug(SIMD2(Float(to.x), Float(to.y))))) < 13 { return true }
      if Self.distance(at, Cable.middle(from, to, angle: angle(cable, from, to))) < 11 { return true }
    }
    if potUnder(at, jacks: jacks) != nil { return true }
    return RackLayout.nearestJack(in: jacks, to: Self.point(at), radius: 16) != nil
  }

  /// What a press on the back starts, by what is under it: an unplug button, a trim pot, a jack, a
  /// cable's belly, a bay.
  func beginBack(at location: SIMD2<Float>, pointer: Int, stage: RackStage) {
    let at = stage.design(location)
    backPointer = at
    let jacks = RackLayout.jacks(stage.placements)
    for cable in rack.patch.cables {
      guard let (_, to) = ends(cable, in: jacks) else { continue }
      if Self.distance(at, Self.point(Self.unplug(SIMD2(Float(to.x), Float(to.y))))) < 13 {
        rack.disconnect(cable)
        return
      }
    }
    if let jack = potUnder(at, jacks: jacks) {
      let key = "\(jack.module).\(jack.port)"
      let now = ContinuousClock.now
      if let last = lastPotTap, last.jack == key, now - last.at < .milliseconds(400) {
        lastPotTap = nil
        rack.setTrim(jack.module, jack.port, to: 1)
        rack.endTurn()
        return
      }
      lastPotTap = (key, now)
      back = .trimming(jack, fromY: location.y, from: rack.trim(jack.module, jack.port))
      return
    }
    if let jack = RackLayout.nearestJack(in: jacks, to: Self.point(at), radius: 16) {
      back = .patching(from: jack)
      return
    }
    for cable in rack.patch.cables {
      guard let (from, to) = ends(cable, in: jacks) else { continue }
      if Self.distance(at, Cable.middle(from, to, angle: angle(cable, from, to))) < 11 {
        rack.disconnect(cable)
        return
      }
    }
    if let placement = stage.placements.first(where: { $0.frame.contains(Self.point(at)) }) {
      rack.select(placement.id)
      back = .moving(id: placement.id, grab: at - SIMD2(Float(placement.x), Float(placement.y)))
      return
    }
    rack.select(nil)
  }

  func moveBack(to location: SIMD2<Float>, modifiers: Modifiers) {
    let stage = stage
    backPointer = stage.design(location)
    if case .trimming(let jack, let fromY, let from) = back {
      // In points on the window, as the reference's pot reads the pointer: a fiftieth a point, a
      // two-hundredth with Shift held.
      let rate = modifiers.contains(.shift) ? 0.005 : 0.02
      rack.setTrim(jack.module, jack.port, to: RackDisplay.trimStep(from + Double(fromY - location.y) * rate))
      lastPotTap = nil
    }
  }

  func endBack(at location: SIMD2<Float>) {
    let stage = stage
    let at = stage.design(location)
    defer {
      back = nil
      backPointer = nil
    }
    switch back {
    case .patching(let from):
      let jacks = RackLayout.jacks(stage.placements)
      guard
        let to = RackLayout.nearestJack(
          in: jacks, to: Self.point(at), radius: RackLayout.snap,
          kind: from.kind == .outlet ? .inlet : .outlet)
      else { return }
      let (outlet, inlet) = from.kind == .outlet ? (from, to) : (to, from)
      rack.connect(PortReference(outlet.module, outlet.port), PortReference(inlet.module, inlet.port))
    case .trimming:
      rack.endTurn()
    case .moving(let id, let grab):
      // Where the carried module's own middle is, not the pointer: it is the module being placed.
      guard let placement = stage.placements.first(where: { $0.id == id }) else { return }
      let centre = CGPoint(
        x: Double(at.x - grab.x) + placement.width / 2, y: Double(at.y - grab.y) + placement.height / 2)
      guard centre != CGPoint(x: placement.x + placement.width / 2, y: placement.y + placement.height / 2)
      else {
        return
      }
      rack.drop(id, at: RackLayout.dropIndex(stage.placements, at: centre))
    case nil:
      break
    }
  }

  // MARK: Drawing

  /// The back, in the rack's design space: bays, cables, the cable in the hand, jacks, the trim
  /// pots and the unplug buttons.
  func drawBack(_ stage: RackStage, on canvas: Canvas) {
    let placements = placements(stage)
    let jacks = RackLayout.jacks(placements)
    let carried: String? = if case .moving(let id, _) = back { id } else { nil }
    let hovered = hover.map { stage.design($0) }

    for placement in placements {
      let rect = Rect(
        Float(placement.x) + 4, Float(placement.y) + 4, Float(placement.width) - 8,
        Float(placement.height) - 8)
      let lifted = placement.id == carried
      if lifted {
        canvas.fill = Colour(0x000000, alpha: 0.4)
        canvas.fillRoundedRect(rect.x + 4, rect.y + 8, rect.width, rect.height, radius: 10)
      }
      canvas.fill = lifted ? Colour(0x18122c) : Self.bay
      canvas.fillRoundedRect(rect.x, rect.y, rect.width, rect.height, radius: 10)
      canvas.stroke = lifted ? Theme.nine.faded(0.6) : Theme.edge
      canvas.lineWidth = 1
      canvas.strokeRoundedRect(rect.x, rect.y, rect.width, rect.height, radius: 10)
      guard let def = RackModules.registry[placement.type] else { continue }
      canvas.align = .left
      canvas.font = Theme.mono(10, weight: 600)
      canvas.fill = Theme.dim
      canvas.fillText(def.name.uppercased(), Float(placement.x) + 14, Float(placement.y) + 25)
      canvas.align = .right
      canvas.font = Theme.mono(8.5)
      canvas.fill = Theme.dim.faded(0.6)
      canvas.fillText(placement.id, Float(placement.x + placement.width) - 14, Float(placement.y) + 25)
    }

    // Cables, each twice: a dark lead under the bright one, so one crossing another stays two.
    let now = Date()
    for (index, cable) in rack.patch.cables.enumerated() {
      guard let (from, to) = ends(cable, in: jacks) else { continue }
      let key = RackSession.key(cable)
      let swing = angle(cable, from, to, at: now)
      let middle = Cable.middle(from, to, angle: swing)
      let over = hovered.map { Self.distance($0, middle) < 11 } ?? false
      let folded = rack.folded.contains(key)
      let curve = Self.curve(from, to, angle: swing)
      canvas.stroke = Colour(0x000000, alpha: 0.55)
      canvas.lineWidth = 7
      canvas.strokeLines(Self.segments(curve))
      canvas.stroke = Self.cableColours[index % 3].faded(folded ? 0.75 : 1)
      canvas.lineWidth = over ? 5 : folded ? 2 : 3.5
      // A cable delayed a block to break a loop is dashed, as the reference draws one.
      canvas.strokeLines(Self.segments(curve, dashed: rack.delayed.contains(key)))
      if over {
        canvas.fill = Theme.white(0.14)
        canvas.fillEllipse(Float(middle.x) - 11, Float(middle.y) - 11, 22, 22)
      }
    }

    // The cable in the hand, to the jack it would land on or to the pointer.
    let target: RackLayout.Jack? = {
      guard case .patching(let from) = back, let pointer = backPointer else { return nil }
      return RackLayout.nearestJack(
        in: jacks, to: Self.point(pointer), radius: RackLayout.snap,
        kind: from.kind == .outlet ? .inlet : .outlet)
    }()
    if case .patching(let from) = back, let pointer = backPointer {
      let end = target?.point ?? Self.point(pointer)
      let (a, b) = from.kind == .outlet ? (from.point, end) : (end, from.point)
      canvas.stroke = Theme.ink.faded(0.7)
      canvas.lineWidth = 3.5
      canvas.strokeLines(Self.segments(Self.curve(a, b, angle: 0)))
    }

    // The jacks.
    let near = hovered.flatMap { RackLayout.nearestJack(in: jacks, to: Self.point($0), radius: 16) }
    for jack in jacks {
      let colour = jack.kind == .inlet ? Theme.nine : Theme.three
      let (x, y) = (Float(jack.x), Float(jack.y))
      let isTarget = target == jack
      let isNear = near == jack
      if jack.stereo {
        canvas.stroke = colour.faded(0.55)
        canvas.lineWidth = 1
        canvas.strokeArc(x, y, radius: 13.5, from: -.pi, to: .pi)
      }
      canvas.fill = isTarget ? Theme.ink : isNear ? Self.lit : Self.jackFill
      canvas.fillEllipse(x - 10, y - 10, 20, 20)
      canvas.stroke = colour
      canvas.lineWidth = isTarget ? 3 : isNear || jack.stereo ? 2.5 : 1.5
      canvas.strokeArc(x, y, radius: 10 - canvas.lineWidth / 2, from: -.pi, to: .pi)
      canvas.fill = Self.hole
      canvas.fillEllipse(x - 4, y - 4, 8, 8)
      canvas.align = jack.kind == .inlet ? .left : .right
      canvas.font = Theme.mono(9)
      canvas.fill = Theme.ink.faded(0.8)
      canvas.fillText(jack.name, x + (jack.kind == .inlet ? 16 : -16), y + 3)
    }

    // The trim pots: teal and bright when off unity, the only time one does anything.
    let turning: RackLayout.Jack? = if case .trimming(let jack, _, _) = back { jack } else { nil }
    let overPot = hovered.flatMap { potUnder($0, jacks: jacks) }
    for jack in jacks where jack.kind == .inlet {
      let centre = Self.pot(jack)
      let value = rack.trim(jack.module, jack.port)
      let on = value != 1
      let active = turning == jack || overPot == jack
      canvas.fill = active ? Self.lit : Self.potFill
      canvas.fillEllipse(centre.x - 7, centre.y - 7, 14, 14)
      canvas.stroke = active ? Theme.ink : on ? Theme.nine : Theme.nine.faded(0.62)
      canvas.lineWidth = active ? 2 : on ? 1.8 : 1.2
      canvas.strokeArc(centre.x, centre.y, radius: 7 - canvas.lineWidth / 2, from: -.pi, to: .pi)
      let angle = Float(RackDisplay.potAngle(value))
      let direction = SIMD2(sin(angle), -cos(angle))
      canvas.stroke = on ? Theme.nine : Theme.ink
      canvas.lineWidth = 1.5
      canvas.strokeLines([(centre + direction * 2, centre + direction * 6)])
      if active {
        let text = RackDisplay.trim(value)
        canvas.font = Theme.mono(9, weight: 600)
        let width = canvas.measure(text)
        canvas.fill = Theme.ground.faded(0.92)
        canvas.fillRoundedRect(centre.x + 9, centre.y - 8, width + 6, 16, radius: 4)
        canvas.align = .left
        canvas.fill = Theme.ink
        canvas.fillText(text, centre.x + 12, centre.y + 3)
      }
    }

    // The unplug buttons, by every inlet a cable is in.
    for cable in rack.patch.cables {
      guard let (_, to) = ends(cable, in: jacks) else { continue }
      let at = Self.unplug(SIMD2(Float(to.x), Float(to.y)))
      let over = hovered.map { Self.distance($0, Self.point(at)) < 13 } ?? false
      canvas.fill = over ? Theme.eight : Theme.ground.faded(0.94)
      canvas.fillEllipse(at.x - 7, at.y - 7, 14, 14)
      canvas.stroke = over ? Theme.ink : Theme.eight
      canvas.lineWidth = over ? 2 : 1.5
      canvas.strokeArc(at.x, at.y, radius: 7 - canvas.lineWidth / 2, from: -.pi, to: .pi)
      canvas.stroke = over ? Theme.ground : Theme.ink
      canvas.lineWidth = 1.5
      canvas.strokeLines([
        (at + SIMD2(-2.5, -2.5), at + SIMD2(2.5, 2.5)), (at + SIMD2(2.5, -2.5), at + SIMD2(-2.5, 2.5)),
      ])
    }

    // A jack a screen reader has taken a cable from, ringed until it is plugged in or put down.
    if let picked, let jack = jacks.first(where: { $0 == picked }) {
      canvas.stroke = Theme.three
      canvas.lineWidth = 2
      canvas.strokeArc(Float(jack.x), Float(jack.y), radius: 12, from: -.pi, to: .pi)
    }
  }

  /// A cable's curve as points along it: close enough together that its lines read as one curve.
  static func curve(_ from: CGPoint, _ to: CGPoint, angle: Double) -> [SIMD2<Float>] {
    let count = 32
    return (0...count).map { index in
      let point = Cable.point(from, to, at: Double(index) / Double(count), angle: angle)
      return SIMD2(Float(point.x), Float(point.y))
    }
  }

  /// A curve as the lines between its points; every other pair of lines, when dashed.
  static func segments(_ curve: [SIMD2<Float>], dashed: Bool = false) -> [(SIMD2<Float>, SIMD2<Float>)] {
    zip(curve, curve.dropFirst()).enumerated().compactMap { index, pair in
      dashed && (index / 2) % 2 == 1 ? nil : pair
    }
  }
}
