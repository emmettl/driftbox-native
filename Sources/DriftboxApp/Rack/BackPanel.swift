#if canImport(SwiftUI) && canImport(AVFoundation)
  import AppKit
  import DriftboxRack
  import SwiftUI

  /// The back of the rack: every module's bay with its jacks, inlets down the left in teal and
  /// outlets down the right in amber, and the cables hanging between them. Drag from a jack to a
  /// jack to patch — from either end, and it snaps — click a cable's belly or the × by its inlet
  /// to pull it out, and it goes up in smoke; drag a bay to move the module, and the cables on it
  /// swing behind. Drawn in the layout's design units, scaled as one piece.
  struct BackPanel: View {
    let model: RackModel
    let layout: RackLayout.Layout
    let scale: Double

    private enum Gesture {
      case patching(from: RackLayout.Jack)
      case moving(id: String, grab: CGPoint)
      case nothing
    }

    @State private var gesture: Gesture?
    @State private var pointer: CGPoint?
    @State private var hover: CGPoint?
    @State private var smoke: [Evaporation] = []
    @State private var motion = Jiggle()
    /// Until when something is moving, so the frame clock can stop when nothing is.
    @State private var animateUntil = Date.distantPast
    @State private var wake = 0

    var body: some View {
      let jacks = placedJacks
      TimelineView(.animation(paused: !animating)) { timeline in
        Canvas { context, _ in
          context.scaleBy(x: scale, y: scale)
          draw(in: &context, jacks: jacks, at: timeline.date)
        }
      }
      .frame(width: layout.width * scale, height: layout.height * scale)
      .contentShape(Rectangle())
      .gesture(drag(jacks))
      .onContinuousHover { phase in
        switch phase {
        case .active(let at): hover = CGPoint(x: at.x / scale, y: at.y / scale)
        case .ended: hover = nil
        }
      }
      .onChange(of: model.flippedAt) { keepAnimating(for: Cable.swingMilliseconds / 1000 + 0.1) }
      .onChange(of: wake) {}
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Rack back panel, \(model.patch.cables.count) cables")
    }

    // MARK: Geometry

    /// The placements, with a module being carried where the pointer has it.
    private var placements: [RackLayout.Placement] {
      guard case .moving(let id, let grab) = gesture, let pointer else { return layout.placements }
      return layout.placements.map { placement in
        guard placement.id == id else { return placement }
        var moved = placement
        moved.x = pointer.x - grab.x
        moved.y = pointer.y - grab.y
        return moved
      }
    }

    private var placedJacks: [RackLayout.Jack] { RackLayout.jacks(placements) }

    private func ends(_ cable: PatchCable, in jacks: [RackLayout.Jack]) -> (CGPoint, CGPoint)? {
      guard
        let from = RackLayout.jack(
          in: jacks, module: cable.from.module, port: cable.from.port, kind: .outlet),
        let to = RackLayout.jack(in: jacks, module: cable.to.module, port: cable.to.port, kind: .inlet)
      else { return nil }
      return (from.point, to.point)
    }

    /// A cable's angle now: its swing since the rack turned, and the carried module's jiggle.
    private func angle(_ cable: PatchCable, _ from: CGPoint, _ to: CGPoint, at date: Date) -> Double {
      let seed = Cable.seed(RackModel.key(cable))
      var angle = 0.0
      if let flipped = model.flippedAt {
        let elapsed = date.timeIntervalSince(flipped) * 1000
        angle += Cable.swing(elapsed, from, to, direction: model.flipped ? 1 : -1, seed: seed)
      }
      if case .moving(let id, _) = gesture, cable.from.module == id || cable.to.module == id {
        angle += motion.angle(at: date) * (0.8 + seed * 0.4)
      } else if motion.carried.map({ cable.from.module == $0 || cable.to.module == $0 }) == true {
        angle += motion.angle(at: date) * (0.8 + seed * 0.4)
      }
      return angle
    }

    // MARK: Drawing

    static let bay = Color.white.opacity(0.02)
    static let jackFill = Color(red: 27 / 255, green: 20 / 255, blue: 48 / 255)
    static let hole = Color(red: 5 / 255, green: 3 / 255, blue: 11 / 255)
    static let outline = Color(red: 11 / 255, green: 7 / 255, blue: 22 / 255)
    static let cableColours = [Theme.nine, Theme.three, Theme.eight]

    private func draw(in context: inout GraphicsContext, jacks: [RackLayout.Jack], at date: Date) {
      let placements = placements
      let carried: String? = if case .moving(let id, _) = gesture { id } else { nil }

      for placement in placements {
        let rect = placement.frame.insetBy(dx: 4, dy: 4)
        let lifted = placement.id == carried
        let shape = Path(roundedRect: rect, cornerRadius: 10)
        if lifted {
          context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.6), radius: 14, y: 8))
            layer.fill(shape, with: .color(Color(red: 24 / 255, green: 18 / 255, blue: 44 / 255)))
          }
        } else {
          context.fill(shape, with: .color(Self.bay))
        }
        context.stroke(shape, with: .color(lifted ? Theme.nine.opacity(0.6) : Theme.edge), lineWidth: 1)
        guard let def = RackModules.registry[placement.type] else { continue }
        context.draw(
          Text(def.name.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.dim),
          at: CGPoint(x: placement.x + 14, y: placement.y + 21), anchor: .leading)
        context.draw(
          Text(placement.id).font(Theme.mono(8.5)).foregroundStyle(Theme.dim.opacity(0.6)),
          at: CGPoint(x: placement.x + placement.width - 14, y: placement.y + 21), anchor: .trailing)
      }

      // Cables, each twice: a dark lead under the bright one, so one crossing another stays two.
      for (index, cable) in model.patch.cables.enumerated() {
        guard let (from, to) = ends(cable, in: jacks) else { continue }
        let key = RackModel.key(cable)
        let angle = angle(cable, from, to, at: date)
        let path = Cable.path(from, to, angle: angle)
        let hovered =
          hover.map {
            hypot(
              $0.x - Cable.middle(from, to, angle: angle).x, $0.y - Cable.middle(from, to, angle: angle).y)
              < 11
          } == true
        context.stroke(
          path, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
        let folded = model.folded.contains(key)
        var style = StrokeStyle(lineWidth: hovered ? 5 : folded ? 2 : 3.5, lineCap: .round)
        if model.delayed.contains(key) { style.dash = [9, 6] }
        context.stroke(
          path, with: .color(Self.cableColours[index % 3].opacity(folded ? 0.75 : 1)), style: style)
        if hovered {
          let middle = Cable.middle(from, to, angle: angle)
          context.fill(
            Path(ellipseIn: CGRect(x: middle.x - 11, y: middle.y - 11, width: 22, height: 22)),
            with: .color(.white.opacity(0.14)))
        }
      }

      // Pulled cables, going up in smoke.
      for evaporation in smoke where date.timeIntervalSince(evaporation.started) < Evaporation.seconds {
        evaporation.draw(in: &context, at: date)
      }

      // The cable in the hand.
      if case .patching(let from) = gesture, let pointer {
        let target = RackLayout.nearestJack(
          in: jacks, to: pointer, radius: RackLayout.snap, kind: from.kind == .outlet ? .inlet : .outlet)
        let end = target?.point ?? pointer
        let (a, b) = from.kind == .outlet ? (from.point, end) : (end, from.point)
        context.stroke(
          Cable.path(a, b), with: .color(Theme.ink.opacity(0.7)),
          style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
      }

      // Jacks on top, then the unplug buttons by every occupied inlet.
      let target: RackLayout.Jack? = {
        guard case .patching(let from) = gesture, let pointer else { return nil }
        return RackLayout.nearestJack(
          in: jacks, to: pointer, radius: RackLayout.snap, kind: from.kind == .outlet ? .inlet : .outlet)
      }()
      let hovered = hover.flatMap { RackLayout.nearestJack(in: jacks, to: $0, radius: 16) }
      for jack in jacks {
        let colour = jack.kind == .inlet ? Theme.nine : Theme.three
        let lit = target == jack
        let over = hovered == jack
        if jack.stereo {
          context.stroke(circle(jack.point, 13.5), with: .color(colour.opacity(0.55)), lineWidth: 1)
        }
        context.fill(
          circle(jack.point, 10),
          with: .color(
            lit ? Theme.ink : over ? Color(red: 42 / 255, green: 31 / 255, blue: 74 / 255) : Self.jackFill))
        context.stroke(
          circle(jack.point, 10), with: .color(colour), lineWidth: lit ? 3 : over || jack.stereo ? 2.5 : 1.5)
        context.fill(circle(jack.point, 4), with: .color(Self.hole))
        let label = Text(jack.name).font(Theme.mono(9)).foregroundStyle(Theme.ink.opacity(0.8))
        let at = CGPoint(x: jack.x + (jack.kind == .inlet ? 16 : -16), y: jack.y)
        let anchor: UnitPoint = jack.kind == .inlet ? .leading : .trailing
        context.draw(
          Text(jack.name).font(Theme.mono(9)).foregroundStyle(Self.outline),
          at: CGPoint(x: at.x + 0.6, y: at.y + 0.6),
          anchor: anchor)
        context.draw(label, at: at, anchor: anchor)
      }
      for cable in model.patch.cables {
        guard let (_, to) = ends(cable, in: jacks) else { continue }
        let at = CGPoint(x: to.x - 18, y: to.y)
        let over = hover.map { hypot($0.x - at.x, $0.y - at.y) < 13 } == true
        context.fill(
          circle(at, 7),
          with: .color(over ? Theme.eight : Color(red: 7 / 255, green: 4 / 255, blue: 15 / 255).opacity(0.94))
        )
        context.stroke(circle(at, 7), with: .color(over ? Theme.ink : Theme.eight), lineWidth: over ? 2 : 1.5)
        var cross = Path()
        cross.move(to: CGPoint(x: at.x - 2.5, y: at.y - 2.5))
        cross.addLine(to: CGPoint(x: at.x + 2.5, y: at.y + 2.5))
        cross.move(to: CGPoint(x: at.x + 2.5, y: at.y - 2.5))
        cross.addLine(to: CGPoint(x: at.x - 2.5, y: at.y + 2.5))
        context.stroke(
          cross, with: .color(over ? Theme.ground : Theme.ink),
          style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
      }
    }

    private func circle(_ centre: CGPoint, _ radius: Double) -> Path {
      Path(
        ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
    }

    // MARK: Hands

    private func drag(_ jacks: [RackLayout.Jack]) -> some SwiftUI.Gesture {
      DragGesture(minimumDistance: 0)
        .onChanged { value in
          let at = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
          if gesture == nil { gesture = begin(at, jacks: jacks) }
          if case .moving = gesture, let pointer { motion.kick(from: pointer, to: at) }
          pointer = at
          keepAnimating(for: 0.1)
        }
        .onEnded { value in
          let at = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
          finish(at, jacks: jacks)
          gesture = nil
          pointer = nil
        }
    }

    /// What a press starts, by what is under it: an unplug button, a jack, a cable, a bay.
    private func begin(_ at: CGPoint, jacks: [RackLayout.Jack]) -> Gesture {
      for cable in model.patch.cables {
        guard let (from, to) = ends(cable, in: jacks) else { continue }
        if hypot(at.x - (to.x - 18), at.y - to.y) < 13 {
          pull(cable, from, to)
          return .nothing
        }
      }
      if let jack = RackLayout.nearestJack(in: jacks, to: at, radius: 16) {
        NSCursor.closedHand.push()
        return .patching(from: jack)
      }
      let now = Date()
      for cable in model.patch.cables {
        guard let (from, to) = ends(cable, in: jacks) else { continue }
        let middle = Cable.middle(from, to, angle: angle(cable, from, to, at: now))
        if hypot(at.x - middle.x, at.y - middle.y) < 11 {
          pull(cable, from, to)
          return .nothing
        }
      }
      if let placement = layout.placements.first(where: { $0.frame.contains(at) }) {
        model.select(placement.id)
        motion.carried = placement.id
        return .moving(id: placement.id, grab: CGPoint(x: at.x - placement.x, y: at.y - placement.y))
      }
      model.select(nil)
      return .nothing
    }

    private func finish(_ at: CGPoint, jacks: [RackLayout.Jack]) {
      switch gesture {
      case .patching(let from):
        NSCursor.pop()
        guard
          let to = RackLayout.nearestJack(
            in: jacks, to: at, radius: RackLayout.snap, kind: from.kind == .outlet ? .inlet : .outlet)
        else { return }
        let (outlet, inlet) = from.kind == .outlet ? (from, to) : (to, from)
        model.connect(PortReference(outlet.module, outlet.port), PortReference(inlet.module, inlet.port))
      case .moving(let id, let grab):
        // Where the carried module's own middle is, not the pointer: it is the module being placed.
        let placement = layout.placements.first { $0.id == id }
        let centre = CGPoint(
          x: at.x - grab.x + (placement?.width ?? 0) / 2, y: at.y - grab.y + (placement?.height ?? 0) / 2)
        let others = layout.placements
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
          model.drop(id, at: RackLayout.dropIndex(others, at: centre))
        }
        keepAnimating(for: 1.5)
      default:
        break
      }
    }

    private func pull(_ cable: PatchCable, _ from: CGPoint, _ to: CGPoint) {
      smoke.append(Evaporation(from: from, to: to, key: RackModel.key(cable), started: Date()))
      model.disconnect(cable)
      keepAnimating(for: Evaporation.seconds)
    }

    // MARK: The frame clock

    private var animating: Bool { gesture != nil || Date() < animateUntil || motion.moving }

    /// Run the frame clock for a while, and wake the view when it can stop.
    private func keepAnimating(for seconds: Double) {
      let until = Date().addingTimeInterval(seconds)
      guard until > animateUntil else { return }
      animateUntil = until
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(seconds + 0.05))
        let now = Date()
        smoke.removeAll { now.timeIntervalSince($0.started) >= Evaporation.seconds }
        wake += 1
      }
    }
  }

  /// The lag of the cables on a module being carried: a damped spring, kicked by how the pointer
  /// moves — the reference's `useCableJiggle`, integrated as the frames are drawn.
  final class Jiggle {
    static let spring = 34.0
    static let damping = 6.5
    static let maxAngle = 0.75
    static let maxSpeed = 5.0

    var carried: String?
    private var angle = 0.0
    private var velocity = 0.0
    private var last: Date?

    var moving: Bool { angle != 0 || velocity != 0 }

    static func impulse(from: CGPoint, to: CGPoint) -> Double {
      let dx = to.x - from.x
      let dy = to.y - from.y
      if dx == 0 && dy == 0 { return 0 }
      let direction: Double = (dx != 0 ? dx : dy) < 0 ? -1 : 1
      return -(dx + direction * abs(dy) * 0.35) * 0.08
    }

    func kick(from: CGPoint, to: CGPoint) {
      velocity = max(-Self.maxSpeed, min(Self.maxSpeed, velocity + Self.impulse(from: from, to: to)))
    }

    func angle(at date: Date) -> Double {
      let dt = min(last.map { date.timeIntervalSince($0) } ?? 0, 0.04)
      last = date
      guard dt > 0 else { return angle }
      velocity += -Self.spring * angle * dt
      velocity *= exp(-Self.damping * dt)
      angle = max(-Self.maxAngle, min(Self.maxAngle, angle + velocity * dt))
      if abs(angle) < 0.002 && abs(velocity) < 0.015 {
        angle = 0
        velocity = 0
        carried = nil
      }
      return angle
    }
  }

  /// A pulled cable, as the reference lets one go: its last curve flares and frays into dashes
  /// while fifteen puffs seeded along it rise, drift, swell and fade.
  struct Evaporation {
    static let seconds = 1.25
    let from: CGPoint
    let to: CGPoint
    let key: String
    let started: Date

    /// CSS's `ease-out`, near enough: fast away, gentle arrival.
    static func easeOut(_ t: Double) -> Double { 1 - pow(1 - max(0, min(1, t)), 2.2) }

    func draw(in context: inout GraphicsContext, at date: Date) {
      let elapsed = date.timeIntervalSince(started) * 1000
      let path = Cable.path(from, to)
      // The flare: wide and pale, widening as it goes, over 560ms.
      let glow = Self.easeOut(elapsed / 560)
      if glow < 1 {
        context.stroke(
          path, with: .color(Theme.ink.opacity(0.42 * (1 - glow))),
          style: StrokeStyle(lineWidth: 11 + 6 * glow, lineCap: .round))
      }
      // The lead fraying: whole, then dashes, then sparse sparks running off, over 720ms.
      let fray = Self.easeOut(elapsed / 720)
      if fray < 1 {
        let early = min(1, fray / 0.38)
        let late = max(0, (fray - 0.38) / 0.62)
        let dash: [CGFloat] =
          fray < 0.38 ? [1 + 10 * early, 0.001 + 5 * early] : [11 - 9 * late, 5 + 14 * late]
        let opacity = fray < 0.38 ? 1 - 0.18 * early : 0.82 * (1 - late)
        context.stroke(
          path, with: .color(Theme.ink.opacity(opacity)),
          style: StrokeStyle(lineWidth: 4 - 3 * fray, lineCap: .round, dash: dash, dashPhase: 52 * fray))
      }
      // The smoke, soft and added on, each puff on its own delay.
      context.drawLayer { layer in
        layer.addFilter(.blur(radius: 1.7))
        layer.blendMode = .screen
        for index in 0..<15 {
          let seed = Cable.seed("\(key):smoke:\(index)")
          let t = (elapsed - (Double(index) * 13 + seed * 32)) / 1050
          guard t > 0, t < 1 else { continue }
          let eased = Self.easeOut(t)
          let origin = Cable.point(from, to, at: 0.04 + Double(index) * 0.066)
          let scale = 0.45 + (4.2 - 0.45) * eased
          let radiusX = (2.5 + seed * 2.8) * scale
          let radiusY = radiusX * (1.25 + seed * 0.5)
          let centre = CGPoint(
            x: origin.x + (seed - 0.5) * 52 * eased, y: origin.y + (-36 - seed * 44) * eased)
          let opacity = t < 0.12 ? 0.72 * t / 0.12 : 0.72 * (1 - (t - 0.12) / 0.88)
          layer.fill(
            Path(
              ellipseIn: CGRect(
                x: centre.x - radiusX, y: centre.y - radiusY, width: radiusX * 2, height: radiusY * 2)),
            with: .color(Color(red: 190 / 255, green: 180 / 255, blue: 230 / 255).opacity(0.76 * opacity)))
        }
      }
    }
  }
#endif
