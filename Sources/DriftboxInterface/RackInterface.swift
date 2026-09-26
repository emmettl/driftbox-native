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
  var menuRequest: (menu: Menu, at: SIMD2<Float>)?
  /// The module a press asked to choose a file for, which the window asks with a panel of its own.
  private var fileRequest: String?
  /// A face asked for the rack's song to be opened in the groovebox, to edit it there.
  private var songRequest = false
  var menuActions: [String: () -> Void] = [:]
  var menuDisabled: Set<String> = []
  var menuChecked: Set<String> = []
  /// One end of a routing being typed: which routing, which end, and what is typed so far.
  var typing: (index: Int, isMax: Bool, text: String)?
  /// On the back: what a press there is doing, and where the pointer is, in the rack's design space.
  var back: BackGesture?
  var backPointer: SIMD2<Float>?
  /// A trim pot let go of without turning, and when: a second, soon after, puts it back to unity.
  var lastPotTap: (jack: String, at: ContinuousClock.Instant)?
  /// The bar a face with more than one shows, or the zone a Key Atlas edits, by module: the Mac
  /// keeps these in the face's view.
  public private(set) var pages: [String: Int] = [:]
  /// A number being dragged has moved far enough to be a drag, not a click.
  private var cellMoved = false
  /// A button held down, and the param it holds: let go of wherever the pointer is.
  private var holding: (pointer: Int, module: String, param: String)?
  /// The knob being turned turns in whole numbers.
  private var turningWhole = false
  /// The keys held with the press: Shift makes a learn chip forget.
  private var pressModifiers: Modifiers = []

  public init(rack: RackSession) {
    self.rack = rack
  }

  public var stage: RackStage {
    RackStage(
      rack: rack, size: size, scroll: scroll, pages: pages, touch: touch, zoom: zoom, pan: pan,
      keys: showsKeys)
  }

  /// Whether the keys show, where a finger has said; otherwise whether the patch has a MIDI module
  /// for them to play.
  public var keysShown: Bool?
  public var showsKeys: Bool {
    touch && (keysShown ?? rack.patch.modules.contains { $0.type == "midi" })
  }
  /// The note each finger on the keys is playing, by the finger; nil for one slid off them.
  private var keyFingers: [Int: Int?] = [:]

  // MARK: - Fingers

  /// For fingers: the rack zoomed and panned about, rather than scrolled by a wheel. Set by the
  /// platform that has a touchscreen, as `Interface.touch` is.
  public var touch = false
  /// How far past fitting the window's width the rack is zoomed, on a touchscreen.
  public private(set) var zoom: Float = 1
  /// How far it is panned from its left edge, in points.
  public private(set) var pan: Float = 0
  /// The way back to the groovebox, where there is one to go back to: the patches' menu offers it.
  public var showGroovebox: (() -> Void)?

  /// Every finger down, and where.
  private var fingers: [Int: SIMD2<Float>] = [:]
  /// Two fingers zooming: how far apart they began, the zoom then, and the point of the rack under
  /// the middle of them, which stays under it.
  private var pinch: (distance: Float, zoom: Float, anchor: SIMD2<Float>)?
  /// A finger on nothing but the rack's panels: a tap if it lifts where it went down, a pan if it
  /// moves, and what it went down on.
  private var sliding: (pointer: Int, from: SIMD2<Float>, last: SIMD2<Float>, moved: Bool, on: RackTarget?)?
  /// Fingers that were part of a pinch, heard no more until they lift.
  private var spent: Set<Int> = []
  /// A finger on a knob or a number, which turns them up and down: not yet moved far enough to say
  /// whether it means to turn it or, going sideways, to pan the rack.
  private var deciding: (pointer: Int, from: SIMD2<Float>)?
  /// The module last tapped, and when: a second tap soon after fits it to the window, or back.
  private var lastModuleTap: (module: String?, at: ContinuousClock.Instant)?
  /// The module the rack is fitted to, after a double tap.
  public private(set) var fitted: String?

  /// Past this many points a finger has slid, not tapped.
  static let slop: Float = 10
  /// A knob's dial across, in the rack's design space, and how many points a finger wants of it.
  static let knobDiameter: Float = 34
  static let fingerKnob: Float = 44

  /// A finger, as a touchscreen has it: two zoom, one on nothing but panels pans, and one on
  /// anything else is a press, as a mouse's is.
  private func finger(_ event: PointerEvent) {
    if keyFingers[event.id] != nil || (event.phase == .began && onKeys(event.location)) {
      playKeys(event)
      return
    }
    switch event.phase {
    case .began:
      fingers[event.id] = event.location
      if fingers.count == 2 {
        // The first finger's press given up for a pinch: whatever it had begun is let go.
        if let other = fingers.keys.first(where: { $0 != event.id }) {
          if sliding?.pointer == other {
            sliding = nil
          } else {
            press(PointerEvent(phase: .cancelled, id: other, kind: .touch, location: fingers[other]!))
          }
          spent.insert(other)
        }
        spent.insert(event.id)
        beginPinch()
        return
      }
      guard fingers.count == 1 else {
        spent.insert(event.id)
        return
      }
      let stage = stage
      if stage.area.contains(event.location), stage.routing?.part(at: event.location) == nil,
        slides(at: event.location, on: stage)
      {
        sliding = (event.id, event.location, event.location, false, stage.target(at: event.location))
        return
      }
      if !rack.flipped, stage.area.contains(event.location) {
        switch stage.target(at: event.location) {
        case .knob, .cell: deciding = (event.id, event.location)
        default: break
        }
      }
      press(event)
    case .moved:
      guard fingers[event.id] != nil else { return }
      fingers[event.id] = event.location
      if pinch != nil {
        movePinch()
        return
      }
      if spent.contains(event.id) { return }
      if let decide = deciding, decide.pointer == event.id {
        let moved = event.location - decide.from
        // Nothing turned until the finger has said which it means.
        guard (moved * moved).sum() > Self.slop * Self.slop else { return }
        deciding = nil
        if abs(moved.x) > abs(moved.y) {
          press(PointerEvent(phase: .cancelled, id: event.id, kind: .touch, location: decide.from))
          sliding = (event.id, decide.from, decide.from, true, nil)
        } else {
          press(event)
          return
        }
      }
      if var slide = sliding, slide.pointer == event.id {
        let moved = event.location - slide.from
        if !slide.moved, (moved * moved).sum() > Self.slop * Self.slop { slide.moved = true }
        if slide.moved {
          let step = event.location - slide.last
          scroll =
            RackStage(
              rack: rack, size: size, scroll: scroll - step.y, pages: pages, touch: true, zoom: zoom, pan: pan
            ).scroll
          pan =
            RackStage(
              rack: rack, size: size, scroll: scroll, pages: pages, touch: true, zoom: zoom, pan: pan - step.x
            ).pan
          fitted = nil
        }
        slide.last = event.location
        sliding = slide
        return
      }
      press(event)
    case .ended, .cancelled:
      fingers[event.id] = nil
      if spent.remove(event.id) != nil {
        if fingers.count < 2 { pinch = nil }
        return
      }
      if let slide = sliding, slide.pointer == event.id {
        sliding = nil
        if !slide.moved, event.phase == .ended { tap(slide.on, at: event.location) }
        return
      }
      if deciding?.pointer == event.id { deciding = nil }
      press(event)
    }
  }

  /// Whether a finger landing at `point` slides the rack about rather than pressing something: on a
  /// panel away from its controls, or on nothing; on the back, anywhere but a jack, a pot or a cable.
  private func slides(at point: SIMD2<Float>, on stage: RackStage) -> Bool {
    if rack.flipped { return !backTakes(at: point, stage: stage) }
    switch stage.target(at: point) {
    case nil, .module: return true
    default: return false
    }
  }

  /// A finger lifted where it went down, on nothing a press takes: selects the module under it, and
  /// a second tap soon after fits the module to the window, or, fitted already, the rack.
  private func tap(_ target: RackTarget?, at point: SIMD2<Float>) {
    var module: String?
    if rack.flipped {
      let at = stage.design(point)
      module = stage.placements.first { $0.frame.contains(Self.point(at)) }?.id
    } else if case .module(let id) = target {
      module = id
    }
    rack.select(module)
    let now = ContinuousClock.now
    if let last = lastModuleTap, last.module == module, now - last.at < .milliseconds(350) {
      lastModuleTap = nil
      if let module, fitted != module {
        fit(module, at: point)
      } else {
        fitRack()
      }
      return
    }
    lastModuleTap = (module, now)
  }

  /// Zoom `module` to a finger's size, its top at the top of the rack's area: to fill the window's
  /// width, a half-width module; and a full-width one, which fills it already, until its knobs are
  /// as big as a finger, the part of it tapped at `point` staying under the finger, and the rest of
  /// it slid to.
  public func fit(_ module: String, at point: SIMD2<Float>? = nil) {
    let before = stage
    guard let placement = before.placements.first(where: { $0.id == module }) else { return }
    let overview = RackStage(rack: rack, size: size, pages: pages, touch: true)
    let across = max(1, overview.area.width - RackStage.inset * 2)
    let filling = across / (Float(placement.width) * overview.fitScale)
    let fingered = Self.fingerKnob / (Self.knobDiameter * overview.fitScale)
    zoom = max(filling, fingered)
    let zoomed = RackStage(rack: rack, size: size, pages: pages, touch: true, zoom: zoom)
    zoom = zoomed.zoom
    var left = Float(placement.x) * zoomed.scale
    if let point, Float(placement.width) * zoomed.scale > across {
      // Wider than the window: the part tapped stays where it was tapped.
      left = RackStage.inset + before.design(point).x * zoomed.scale - point.x
    }
    pan = RackStage(rack: rack, size: size, pages: pages, touch: true, zoom: zoom, pan: left).pan
    scroll =
      RackStage(
        rack: rack, size: size, scroll: Float(placement.y) * zoomed.scale, pages: pages, touch: true,
        zoom: zoom, pan: pan
      ).scroll
    fitted = module
  }

  /// The whole rack's width in the window again.
  public func fitRack() {
    let ratio = 1 / zoom
    zoom = 1
    pan = 0
    scroll = RackStage(rack: rack, size: size, scroll: scroll * ratio, pages: pages, touch: true).scroll
    fitted = nil
  }

  private func beginPinch() {
    let points = Array(fingers.values)
    guard points.count == 2 else { return }
    let middle = (points[0] + points[1]) / 2
    let apart = distance(points[0], points[1])
    pinch = (max(1, apart), zoom, stage.design(middle))
    sliding = nil
  }

  private func movePinch() {
    guard let pinch else { return }
    let points = Array(fingers.values)
    guard points.count == 2 else { return }
    let middle = (points[0] + points[1]) / 2
    let apart = distance(points[0], points[1])
    zoom =
      RackStage(rack: rack, size: size, pages: pages, touch: true, zoom: pinch.zoom * apart / pinch.distance)
      .zoom
    // The point of the rack that was under the fingers stays under them.
    let zoomed = RackStage(rack: rack, size: size, pages: pages, touch: true, zoom: zoom)
    pan =
      RackStage(
        rack: rack, size: size, pages: pages, touch: true, zoom: zoom,
        pan: RackStage.inset + pinch.anchor.x * zoomed.scale - middle.x
      ).pan
    scroll =
      RackStage(
        rack: rack, size: size, scroll: pinch.anchor.y * zoomed.scale - (middle.y - zoomed.area.y),
        pages: pages,
        touch: true, zoom: zoom, pan: pan
      ).scroll
    fitted = nil
  }

  private func distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
    let d = a - b
    return (d * d).sum().squareRoot()
  }

  /// Points of drag, in the rack's own units, for a number to move one: as the Mac's cells have it.
  public static let cellStep: Float = 4

  /// Points of drag for a knob's whole travel, as the groovebox's knobs have it.
  public static let travel: Float = 170

  // MARK: - The pointer

  /// Take `event`: the rack is the whole window while it shows. On a touchscreen a finger may zoom
  /// or pan it instead of pressing; a mouse always presses.
  public func pointer(_ event: PointerEvent) {
    if touch, event.kind != .mouse {
      finger(event)
    } else {
      press(event)
    }
  }

  /// A press, as a mouse makes one.
  private func press(_ event: PointerEvent) {
    if event.kind == .mouse { hover = event.phase == .cancelled ? nil : event.location }
    switch event.phase {
    case .began:
      // A press anywhere sets an end being typed, as leaving a field does.
      if typing != nil { finishTyping() }
      let stage = stage
      let target = stage.target(at: event.location)
      // The back is its own: patching, trimming, carrying modules. The header is still the header.
      if rack.flipped, stage.area.contains(event.location) {
        beginBack(at: event.location, pointer: event.id, stage: stage)
        return
      }
      pressed = (event.id, target)
      pressModifiers = event.modifiers
      switch target {
      case .knob(let module, let param):
        guard let value = value(module, param) else { break }
        turningWhole =
          stage.faces.first { $0.module.id == module }?.controls.first { $0.param.id == param }?.whole
          ?? false
        turning = (event.id, target!, event.location.y, value, value)
      case .tempo:
        turning = (event.id, .tempo, event.location.y, rack.tempo, rack.tempo)
      case .cell(let module, let index):
        guard let cell = cell(module, index, in: stage) else { break }
        cellMoved = false
        turning = (event.id, target!, event.location.y, Double(cell.value), Double(cell.value))
      case .button(let module, let index):
        // A button held is heard from the press, and let go of wherever the pointer is then.
        guard let face = stage.faces.first(where: { $0.module.id == module }),
          face.buttons.indices.contains(index), case .hold(let param) = face.buttons[index].press
        else { break }
        rack.turn(module, param, to: 1)
        holding = (event.id, module, param)
      case .routing(.min(let index)), .routing(.max(let index)):
        // On a touchscreen, where there are no keys to type an end with, it is dragged instead.
        guard touch, let (from, _) = routeEnd(index, isMax: target == .routing(.max(index))) else { break }
        turning = (event.id, target!, event.location.y, from, from)
      case .module(let id):
        rack.select(id, adding: event.modifiers.contains(.control))
      case nil:
        if stage.area.contains(event.location) { rack.select(nil) }
      default:
        break
      }
    case .moved:
      if back != nil {
        moveBack(to: event.location, modifiers: event.modifiers)
        return
      }
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
        if turningWhole { turn.value = RackDisplay.jsRound(turn.value) }
        // Heard as it turns, as the Mac's knobs are: the first move is what undo goes back to.
        rack.turn(module, param, to: turn.value)
      case .routing(.min(let index)), .routing(.max(let index)):
        let isMax = turn.target == .routing(.max(index))
        guard let (_, def) = routeEnd(index, isMax: isMax) else { return }
        let span = def.max - def.min
        let moved = rise / Double(Self.travel) * span * (fine ? 0.25 : 1)
        var value = max(def.min, min(def.max, turn.from + moved))
        if def.stepped { value = value.rounded() }
        turn.value = value
        rack.turnRoute(index) { route in
          if isMax { route.max = value } else { route.min = value }
        }
      case .cell(let module, let index):
        let stage = stage
        guard let cell = cell(module, index, in: stage) else { return }
        let travel = Float(rise) / stage.scale
        if abs(travel) >= cell.step { cellMoved = true }
        guard cellMoved else { return }
        let next = max(
          cell.range.lowerBound,
          min(
            cell.range.upperBound, Int(turn.from) + Int(RackDisplay.jsRound(Double(travel / cell.step)))))
        if next != cell.value {
          if let writes = cell.writes {
            // As it turns: written, and the whole drag one step of undo.
            switch writes(next) {
            case .data(let slot, let values, let name, _, _):
              rack.setData(module, slot, to: values, name: name)
            case .set(let param, let value): rack.turn(module, param, to: value)
            default: break
            }
          } else if let (id, offset, scale) = cell.param {
            rack.turn(module, id, to: offset + scale * Double(next))
          } else {
            let data = rack.patch.modules.first { $0.id == module }?.data[cell.slot] ?? []
            rack.setData(module, cell.slot, to: cell.written(next, in: data), name: cell.name)
          }
        }
        turn.value = Double(next)
      default:
        return
      }
      turning = turn
    case .ended:
      if back != nil {
        endBack(at: event.location)
        return
      }
      guard let press = pressed, press.pointer == event.id else { return }
      pressed = nil
      if let held = holding, held.pointer == event.id {
        holding = nil
        rack.turn(held.module, held.param, to: 0)
        rack.endTurn()
        return
      }
      if let turn = turning, turn.pointer == event.id {
        turning = nil
        finish(turn)
      } else if let target = press.target, stage.target(at: event.location) == target {
        perform(target, at: event.location)
      }
    case .cancelled:
      pressed = nil
      if let held = holding {
        holding = nil
        rack.turn(held.module, held.param, to: 0)
        rack.endTurn()
      }
      back = nil
      backPointer = nil
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
    case .cell(let module, let index):
      rack.endTurn()
      // Not dragged: a click, which does what the number does when clicked, if it does anything.
      if !cellMoved, let press = cell(module, index, in: stage)?.click { self.press(press, on: module) }
      cellMoved = false
    case .routing:
      rack.endTurn()
    default:
      break
    }
  }

  /// One end of routing `index`, as it is, or its target's own limit where it has none; and the
  /// target's param, whose range it is dragged across.
  private func routeEnd(_ index: Int, isMax: Bool) -> (Double, ParamDef)? {
    guard rack.patch.modulation.indices.contains(index) else { return nil }
    let route = rack.patch.modulation[index]
    guard let type = rack.patch.modules.first(where: { $0.id == route.to.module })?.type,
      let def = RackSession.routable(type).first(where: { $0.id == route.to.port })
    else { return nil }
    return ((isMax ? route.max : route.min) ?? (isMax ? def.max : def.min), def)
  }

  /// The number `index` on `module`'s face.
  private func cell(_ module: String, _ index: Int, in stage: RackStage) -> RackStage.Cell? {
    guard let face = stage.faces.first(where: { $0.module.id == module }), face.cells.indices.contains(index)
    else { return nil }
    return face.cells[index]
  }

  /// What one of a face's buttons or numbers does, on `module`.
  /// What a press on a face's button or number does; a menu it asks for opens under `frame`.
  private func press(_ press: RackStage.Press, on module: String, from frame: Rect? = nil) {
    let under = frame.map { SIMD2($0.x, $0.maxY) } ?? .zero
    switch press {
    case .set(let param, let value):
      rack.set(module, param, to: value)
    case .data(let slot, let values, let name, let then, let to):
      rack.setData(module, slot, to: values, name: name)
      rack.endTurn()
      if let then { rack.set(module, then, to: to) }
    case .page(let page):
      pages[module] = page
    case .hold:
      break  // Held from the press itself, not its lift.
    case .choose:
      fileRequest = module
    case .sampleBars(let bars):
      rack.setSampleBars(module, bars)
    case .editSong:
      songRequest = true
    case .startSong(let bar):
      rack.startSong(atBar: bar)
    case .loopSong(let start, let bars):
      if let loop = rack.songLoop, loop.start == start, loop.bars == bars {
        rack.clearSongLoop()
      } else {
        rack.loopSong(start: start, bars: bars)
      }
    case .clearLoop:
      rack.clearSongLoop()
    case .routes:
      rack.editRoutes(rack.editingRoutes == module ? nil : module)
    case .plugin:
      menuRequest = (pluginMenu(module), under)
    case .macros:
      menuRequest = (macroMenu(module), under)
    case .learn(let param):
      if pressModifiers.contains(.shift) {
        rack.clearCcBinding(module, param)
      } else if rack.ccLearning == PortReference(module, param) {
        rack.cancelCcLearn()
      } else {
        rack.startCcLearn(module, param)
      }
    }
  }

  private func perform(_ target: RackTarget, at point: SIMD2<Float>) {
    switch target {
    case .run: rack.toggleRunning()
    case .flip: rack.flip()
    case .add: menuRequest = (addMenu(), point)
    case .keys:
      if showsKeys { releaseKeyFingers() }
      keysShown = !showsKeys
    case .octave(let by): octave = max(-2, min(3, octave + by))
    case .patches:
      if let chip = stage.chips.first(where: { $0.target == .patches }) {
        menuRequest = (patchMenu(), SIMD2(chip.frame.x, chip.frame.maxY))
      }
    case .option(let module, let param, let value): rack.set(module, param, to: Double(value))
    case .step(let module, let param, let by):
      guard let def = def(module, param), let value = value(module, param) else { return }
      let next = max(def.min, min(def.max, value.rounded() + Double(by)))
      rack.set(module, param, to: next)
    case .button(let module, let index):
      guard let face = stage.faces.first(where: { $0.module.id == module }),
        face.buttons.indices.contains(index), let press = face.buttons[index].press
      else { return }
      self.press(press, on: module, from: face.buttons[index].frame)
    case .routing(let part):
      perform(part, at: point)
    default:
      break
    }
  }

  /// The module a press asked to choose a file for, once: the window asks with its own panel and
  /// hands what is chosen to `load`.
  public func takeFileRequest() -> String? {
    defer { fileRequest = nil }
    return fileRequest
  }

  /// Whether a face asked, since last asked, for the rack's song to be edited in the groovebox.
  public func takeSongRequest() -> Bool {
    defer { songRequest = false }
    return songRequest
  }

  /// Whether the module takes several files at once, as a Multisampler takes a set.
  public func takesSeveral(_ module: String) -> Bool {
    rack.patch.modules.first { $0.id == module }?.type == "multisampler"
  }

  /// Files into a module that holds recordings, as its kind takes them: a sample, a track, or a set
  /// mapped into an instrument. Read off the main thread; the face says so while they are. False
  /// for a module that holds none.
  @discardableResult
  public func load(_ urls: [URL], into module: String) -> Bool {
    guard let url = urls.first, let type = rack.patch.modules.first(where: { $0.id == module })?.type
    else { return false }
    let rack = rack
    switch type {
    case "sampler": Task { await rack.load(url, into: module) }
    case "audio-track": Task { await rack.loadTrack(url, into: module) }
    case "multisampler":
      // A new set, edited from its first zone.
      pages[module] = 0
      Task { await rack.loadInstrument(urls, into: module) }
    default: return false
    }
    return true
  }

  /// Files dropped on the window at `point`: into the module there, if it holds recordings. False
  /// when nothing there takes them, for the window to do something else with them.
  public func drop(_ urls: [URL], at point: SIMD2<Float>) -> Bool {
    guard !rack.flipped, let face = stage.face(at: point) else { return false }
    return load(urls, into: face.module.id)
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

  /// Whether `point` is on the keys themselves, rather than their row.
  private func onKeys(_ point: SIMD2<Float>) -> Bool {
    guard let keys = stage.keyboard, keys.frame.contains(point) else { return false }
    return point.y >= keys.frame.y + RackKeys.rowHeight
  }

  /// A finger on the keys: a note from where it lands, the next as it slides onto another key, and
  /// none as it slides off; let go of as it lifts.
  private func playKeys(_ event: PointerEvent) {
    let found = stage.keyboard?.key(at: event.location)
    let note = found.map { RackKeyboard.root + $0.key.note + octave * 12 }
    switch event.phase {
    case .began, .moved:
      let playing = keyFingers[event.id] ?? nil
      guard note != playing else { return }
      if let playing { rack.noteUp(playing) }
      if let note, let found { rack.noteDown(note, velocity: found.velocity) }
      keyFingers[event.id] = .some(note)
    case .ended, .cancelled:
      if let playing = keyFingers.removeValue(forKey: event.id), let playing { rack.noteUp(playing) }
    }
  }

  /// Every finger on the keys lifted, as when the keys are put away.
  private func releaseKeyFingers() {
    for case let note? in keyFingers.values { rack.noteUp(note) }
    keyFingers = [:]
  }

  /// The notes the keys have down, for the keys to light.
  var keysDown: Set<Int> { Set(keyFingers.values.compactMap { $0 }) }

  /// The keys, as the Mac's rack window plays them: two octaves from `z` and `q`, with `,` and `.`
  /// for the octave. False for any other key, and for anything held with more than Shift.
  public func key(_ event: KeyEvent) -> Bool {
    // An end of a routing being typed has every key.
    if typing != nil { return type(event) }
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
    menuChecked = []
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
  /// The patches to open, and the way back to the groovebox where there is one.
  func patchMenu() -> Menu {
    menuActions = [:]
    menuDisabled = []
    menuChecked = []
    var items: [MenuItem] = []
    if let showGroovebox {
      items += [item("Groovebox", "rack.groovebox", enabled: true) { showGroovebox() }, .separator]
    }
    let patches = PatchEntry.all.map { entry -> MenuItem in
      let id = "patch." + entry.id
      if rack.name == entry.name { menuChecked.insert(id) }
      return item(entry.name, id, enabled: true) { [weak self] in
        self?.rack.open(entry)
        self?.fitRack()
      }
    }
    items.append(.submenu(Menu("Patches", patches)))
    return Menu(rack.name, items)
  }

  func addMenu() -> Menu {
    menuActions = [:]
    menuDisabled = []
    menuChecked = []
    var groups: [String] = []
    var types: [String: [String]] = [:]
    for card in ModuleFace.all where RackModules.registry[card.type] != nil {
      if RackModules.pluginTypes.contains(card.type) { continue }
      let group = card.group ?? "Other"
      if types[group] == nil { groups.append(group) }
      types[group, default: []].append(card.type)
    }
    let modules: [MenuItem] = groups.map { group in
      .submenu(
        Menu(
          group,
          (types[group] ?? []).map { type in
            item(RackModules.registry[type]?.name ?? type, "add.\(type)") { self.rack.add(type) }
          }))
    }
    guard rack.hostsPlugins else { return Menu("Add", modules) }
    rack.findPlugins()
    return Menu("Add", modules + [.separator] + pluginMenus())
  }

  public func menuIsEnabled(_ id: String) -> Bool { !menuDisabled.contains(id) }
  public func menuIsChecked(_ id: String) -> Bool { menuChecked.contains(id) }

  public func choose(_ id: String) {
    guard menuIsEnabled(id), let action = menuActions[id] else { return }
    menuActions = [:]
    action()
  }

  func item(
    _ title: String, _ id: String, enabled: Bool = true, checked: Bool = false, _ action: @escaping () -> Void
  ) -> MenuItem {
    menuActions[id] = action
    if !enabled { menuDisabled.insert(id) }
    if checked { menuChecked.insert(id) }
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
    if rack.flipped {
      drawBack(stage, on: canvas)
    } else {
      for face in stage.faces { drawFace(face, hovered: hovered, on: canvas) }
    }
    canvas.restore()
    drawHeader(stage, on: canvas)
    if let routing = stage.routing { drawRouting(routing, hovered: hover, on: canvas) }
    if let chip = stage.keysChip {
      Draw.chip(
        chip.frame, label: chip.label, isOn: false, hovered: false, down: pressed?.target == .keys, on: canvas
      )
    }
    if let keys = stage.keyboard { drawKeys(keys, on: canvas) }
  }

  /// The keys: a panel across the foot, its row of chips and the octave, and the keys, lit where a
  /// finger or the rack's own notes have them down.
  private func drawKeys(_ keys: RackKeys, on canvas: Canvas) {
    Draw.panel(keys.frame, on: canvas)
    Draw.chip(
      keys.down, label: "‹", isOn: false, hovered: false, down: pressed?.target == .octave(by: -1), on: canvas
    )
    Draw.chip(
      keys.up, label: "›", isOn: false, hovered: false, down: pressed?.target == .octave(by: 1), on: canvas)
    Draw.chip(
      keys.hide, label: "HIDE", isOn: false, hovered: false, down: pressed?.target == .keys, on: canvas)
    canvas.align = .center
    canvas.font = Theme.mono(13, weight: 600)
    canvas.fill = Theme.ink
    let base = RackKeyboard.root + octave * 12
    canvas.fillText(
      "C\(base / 12 - 1)", keys.octave.x + keys.octave.width / 2, keys.octave.y + keys.octave.height / 2 + 5)
    let lit = keysDown.union(rack.sounding)
    for key in keys.keys where !key.black { drawKey(key, lit: lit.contains(base + key.note), on: canvas) }
    for key in keys.keys where key.black { drawKey(key, lit: lit.contains(base + key.note), on: canvas) }
  }

  private func drawKey(_ key: RackKeys.Key, lit: Bool, on canvas: Canvas) {
    let frame = key.frame
    canvas.fill = lit ? Theme.nine : key.black ? Theme.ground : Theme.ink.faded(0.9)
    canvas.fillRoundedRect(frame.x, frame.y, frame.width, frame.height, radius: key.black ? 4 : 6)
    canvas.stroke = Theme.white(0.12)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(frame.x, frame.y, frame.width, frame.height, radius: key.black ? 4 : 6)
    guard !key.black, key.note % 12 == 0 else { return }
    canvas.align = .center
    canvas.font = Theme.mono(10, weight: 500)
    canvas.fill = Theme.ground.faded(0.7)
    canvas.fillText(
      "C\((RackKeyboard.root + key.note + octave * 12) / 12 - 1)", frame.x + frame.width / 2, frame.maxY - 10)
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
    if stage.keys.width > 0 { canvas.fillText("keys C\(2 + octave)", stage.keys.x, baseline) }
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
    // The title: the name, and at the right what its jacks add up to or what the face is doing,
    // over a hairline.
    let title = face.title
    let baseline = title.y + title.height / 2 + 4
    canvas.align = .left
    canvas.font = Theme.mono(11, weight: 600)
    canvas.fill = Theme.ink.faded(dim)
    canvas.fillText((face.name ?? def.name).uppercased(), title.x, baseline)
    if let mark = face.mark {
      let name = canvas.measure((face.name ?? def.name).uppercased())
      canvas.font = Theme.mono(8)
      canvas.fill = (face.markTint ?? Theme.three).faded(dim)
      canvas.fillText(mark, title.x + name + 8, baseline)
    }
    canvas.align = .right
    canvas.font = face.wordsFont ?? (face.wordsTint == nil ? Theme.mono(9) : Theme.mono(10, weight: 600))
    canvas.fill = face.wordsTint?.faded(dim) ?? Theme.dim.faded(0.8 * dim)
    canvas.fillText(face.words, title.maxX, baseline)
    if let light = face.light {
      // A light before the words: lit when the module has what it needs.
      let x = title.maxX - canvas.measure(face.words) - 8
      canvas.fill = light ? Theme.nine : Theme.dim.faded(0.4)
      canvas.fillEllipse(x - 2.5, baseline - 5.5, 5, 5)
    }
    canvas.fill = Theme.edge
    canvas.fillRect(title.x, title.maxY + 4, title.width, 1)
    let tint = Self.tint(ModuleFace.byType[def.type]?.group)
    for control in face.controls {
      drawControl(control, module: face.module, tint: tint, hovered: hovered, on: canvas)
    }
    drawScreen(face, hovered: hovered, on: canvas)
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
    let tint = control.tint ?? tint
    let opacity = control.opacity
    let labels = control.labels ?? ModuleFace.byType[module.type]?.labels[def.id]
    switch control.kind {
    case .knob(let dial):
      let span = def.max - def.min
      Draw.knob(
        dial, value: span == 0 ? 0 : (value - def.min) / span, label: control.name ?? def.name,
        text: control.display?(value) ?? RackDisplay.value(def, value), tint: tint, active: active,
        hovered: hovered.map(control.cell.contains) ?? false, opacity: opacity,
        labelWidth: control.cell.width - 4,
        on: canvas)
    case .options(let buttons):
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
      name(control.name ?? def.name, in: control.cell, on: canvas)
    case .stepper(let shown, let down, let up):
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
      name(control.name ?? def.name, in: control.cell, on: canvas)
    }
    // A Combinator drives it: marked rather than disabled, as the reference marks it.
    if rack.isRouted(module.id, def.id) {
      canvas.fill = Theme.three
      canvas.fillEllipse(control.cell.maxX - 11, control.cell.y + 2, 5, 5)
    }
  }

  private func name(_ name: String, in cell: Rect, on canvas: Canvas) {
    canvas.align = .center
    let shown = Draw.fit(name.uppercased(), width: cell.width - 6, size: 8.5, weight: 500, on: canvas)
    canvas.fill = Theme.dim
    canvas.fillText(shown, cell.x + cell.width / 2, cell.y + 57)
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
