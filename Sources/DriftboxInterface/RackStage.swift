import DriftboxCanvas
import DriftboxRack
import DriftboxRackSession
import DriftboxText

/// What pressing something on the rack does, or which control it turns.
public enum RackTarget: Equatable, Sendable {
  /// Start or stop the rack's transport.
  case run
  /// Offer the modules to add.
  case add
  /// Turn the rack round, to its back or its front.
  case flip
  /// The tempo, dragged as a number.
  case tempo
  /// A module's panel, away from its controls: select it.
  case module(String)
  /// A knob, turned by dragging.
  case knob(module: String, param: String)
  /// One of a choice's buttons.
  case option(module: String, param: String, value: Int)
  /// A choice of more than three, stepped down or up.
  case step(module: String, param: String, by: Int)
  /// One of a face's own buttons, by its place in the face's list.
  case button(module: String, index: Int)
  /// One of a face's numbers, dragged for its value and clicked to act: a tracker's step, an
  /// arranger's section.
  case cell(module: String, index: Int)
  /// Part of the Combinator's routing, open beside the rack.
  case routing(RoutingPart)
  /// On a touchscreen, the patch's name: the patches to open, and the way back to the groovebox.
  case patches
  /// On a touchscreen, the keys shown or put away.
  case keys
  /// The keys' octave, down or up.
  case octave(by: Int)
}

/// What a press on a Combinator's routing is on: its close and add buttons, and each routing's
/// source, target module and knob, its two ends, and its remove button, by its place among the
/// patch's routings.
public enum RoutingPart: Equatable, Sendable {
  case close
  case add
  case source(Int)
  case module(Int)
  case knob(Int)
  case min(Int)
  case max(Int)
  case remove(Int)
}

/// Where everything on the rack is, for a window `size` points across: the header in points, and
/// the rack under it in the rack's own design space — `RackLayout`'s, the reference's — drawn at
/// `scale` from `origin`, so that a face is laid out once in the units every face is designed in.
public struct RackStage {
  public static let margin: Float = 12
  public static let headerHeight: Float = 44
  /// The largest the rack is drawn before a finger zooms it: about the reference's size, a little
  /// larger. Past this the panels stop reading as a rack of modules and start reading as a poster
  /// of one.
  static let largest: Float = 1.35

  /// A button in the header.
  public struct Chip {
    public var frame: Rect
    public var label: String
    public var target: RackTarget
    public var isOn: Bool
  }

  /// One param's control on a face, in design space.
  public struct Control {
    public enum Kind: Equatable {
      /// A knob for a range: its dial.
      case knob(dial: Rect)
      /// A button for each of up to three choices.
      case options([Rect])
      /// A choice of more: where its value is said, and the buttons down and up.
      case stepper(value: Rect, down: Rect, up: Rect)
    }
    public var param: ParamDef
    public var cell: Rect
    public var kind: Kind
    /// The face's own colour for it, where it has one; the module's otherwise.
    public var tint: Colour?
    /// A shorter name than the param's, where the face already says whose control it is.
    public var name: String?
    /// Words for a choice's values, where the face has its own.
    public var labels: [String]?
    /// Faint when asleep: a pulse's width while the shape is not a pulse.
    public var opacity: Float = 1
    /// Its value in words of its own, where the param's range is not what it means.
    public var display: (@Sendable (Double) -> String)?
    /// Turned in whole numbers.
    public var whole = false
  }

  /// Where a Combinator's routing is, beside the rack, when it is open.
  public var routing: Routing?

  /// A module's front, in design space.
  public struct Face {
    public var module: PatchModule
    /// Nil for a module this build cannot make.
    public var def: ModuleDef?
    public var span: Int
    public var frame: Rect
    public var title: Rect
    /// What the title says at its right: what its jacks add up to, or what a hand-built face is doing.
    public var words: String
    /// The words' colour, where they are lit.
    public var wordsTint: Colour?
    /// The words' font, where it is not the usual.
    public var wordsFont: FontRequest?
    public var controls: [Control]
    /// A model mark after the name, in its own colour.
    public var mark: String?
    public var markTint: Colour?
    /// The name the title gives, where the face has one of its own.
    public var name: String?
    /// A light before the words: lit when the module has what it needs, as a loaded sample.
    public var light: Bool?
    /// Where a face that meters draws what it reads: a tuner's display, a meter's, a looper's.
    public var screen: Rect?
    /// Buttons that set a param to a value, as a looper's transport does.
    public var buttons: [Button] = []
    public var cells: [Cell] = []
  }

  /// What a press on one of a face's own buttons or numbers does.
  public enum Press: Equatable, Sendable {
    /// Set a param.
    case set(param: String, value: Double)
    /// Write a data slot, one step of undo called `name`; and then set a param, where `then` says one.
    case data(slot: String, values: [Double], name: String, then: String? = nil, to: Double = 0)
    /// Show another bar of a face's steps.
    case page(Int)
    /// Set a param to one while the button is held, and back to nothing when it is let go: one
    /// step of undo.
    case hold(param: String)
    /// Learn a controller for a param: or stop waiting for one, or, with Shift, forget it.
    case learn(param: String)
    /// Choose a file to load into the module.
    case choose
    /// Take the sample to be this many bars long.
    case sampleBars(Int)
    /// Open the rack's song in the groovebox, linked, to edit it there.
    case editSong
    /// Play the rack's song from a bar.
    case startSong(bar: Int)
    /// Loop bars of the rack's song, or stop looping them if they are what loops.
    case loopSong(start: Int, bars: Int)
    /// Stop looping the rack's song.
    case clearLoop
    /// Open the Combinator's routing beside the rack, or close it.
    case routes
    /// Choose the plug-in a plug-in module hosts, from a menu of those there are.
    case plugin
    /// Map a plug-in module's macros onto its plug-in's params, from a menu.
    case macros
    /// Open a plug-in module's plug-in's own editor.
    case open

    /// The param it sets, if it sets one.
    public var param: String? {
      switch self {
      case .set(let param, _): param
      case .data(_, _, _, let then, _): then
      case .page, .learn, .choose, .sampleBars, .editSong, .startSong, .loopSong, .clearLoop, .routes,
        .plugin, .macros, .open:
        nil
      case .hold(let param): param
      }
    }
  }

  /// A button on a face of its own.
  public struct Button {
    public enum Style: Equatable, Sendable {
      /// A looper's transport: small capitals, lit in its colour.
      case transport
      /// As a choice's buttons are.
      case option
      /// Words only, as a tracker lane's mode is.
      case tag
      /// A key of a scale's keyboard.
      case key(black: Bool, root: Bool)
      /// One of an echo's pulses, as tall as its velocity.
      case pulse(amount: Double)
      /// A button held down, round, as a chord player's Alter is.
      case capsule
      /// One of a chord's voices: its lane, its note as the label, and its octave from the root.
      case voice(lane: Int, badge: String)
      /// One of an arp's rhythm steps: the note it would play as the label, and its octave.
      case arpStep(number: Int, octave: Int)
      /// A control's MIDI learn: waiting for a controller, or holding one it learnt.
      case learn(armed: Bool, bound: Bool)
      /// A combinator's button, marked when it drives anything.
      case pad(live: Bool)
      /// One of a sampler's slices, a beat's first edged brighter.
      case slice(accent: Bool)
      /// A screen with nothing on it yet, asking for a file: its label, and `detail` under it.
      case prompt(detail: String)
      /// As a stepper's buttons are.
      case chip
      /// A multisample zone on its map: where its root is across it, and the root's name.
      case zone(root: Float, note: String)
    }
    public var frame: Rect
    public var label: String
    public var press: Press?
    public var isOn: Bool
    public var tint: Colour
    /// The label's colour while it is off, where it is not the usual.
    public var text: Colour?
    public var style: Style = .transport
    /// Faint when it does nothing, or its lane is muted.
    public var opacity: Float = 1
  }

  /// A number on a face that a drag changes and a click acts on, written into a data slot.
  public struct Cell {
    public var frame: Rect
    public var value: Int
    public var range: ClosedRange<Int>
    /// Where it is written: the slot, the place in it, and what the slot is padded with to reach it.
    public var slot: String
    public var index: Int
    public var padTo: Int
    public var pad: Double
    public var name: String
    public var click: Press?
    /// Drawn as a step, lit when it plays, or as a plain number.
    public var isStep = false
    /// A param it sets rather than a slot it writes: `offset` and `scale` times its value.
    public var param: (id: String, offset: Double, scale: Double)?
    /// Points of drag, in the rack's units, for one step of it.
    public var step: Float = 4
    /// Its name, beside it at the left.
    public var caption: String?
    /// What its value writes, where it is neither a slot's place nor a param: a zone's field, say.
    public var writes: (@Sendable (Int) -> Press)?
    /// Its value in words of its own: a note's name, a fraction.
    public var text: (@Sendable (Int) -> String)?
    /// Drawn as a field, a label and a large number, rather than a box.
    public var field = false
    /// The first step of a beat, edged a little brighter.
    public var accent = false
    public var opacity: Float = 1

    /// The slot with this cell set to `value`.
    func written(_ value: Int, in data: [Double]) -> [Double] {
      var values = data
      while values.count < max(padTo, index + 1) { values.append(pad) }
      values[index] = Double(value)
      return values
    }
  }

  public var size: SIMD2<Float>
  public var header: Rect
  public var chips: [Chip]
  /// The tempo's number, dragged as the transport's is.
  public var tempo: Rect
  /// Where the patch's name and what the keys play are said.
  public var title: Rect
  public var keys: Rect

  /// Where the rack is seen: the window under the header.
  public var area: Rect
  /// Where the rack's design space starts on the window, and how many points to its unit.
  public var origin: SIMD2<Float>
  public var scale: Float
  public var faces: [Face]
  /// Where each module is, as the rack's layout has it: the back draws its bays and jacks from these.
  public var placements: [RackLayout.Placement]
  /// The rack's height in design space.
  public var height: Float
  public var scroll: Float
  public var maxScroll: Float
  /// On a touchscreen: the rack drawn for fingers, which zoom it and pan it about.
  public var touch = false
  /// How far the rack is zoomed past fitting the window's width, on a touchscreen; 1 on a desktop.
  public var zoom: Float = 1
  /// How far the rack is panned from its left edge, in points, when zoomed wider than the window.
  public var pan: Float = 0
  public var maxPan: Float = 0
  /// The scale at which the rack's width fits the window, which a zoom multiplies.
  public var fitScale: Float = 1
  /// On a touchscreen, the keys at the foot of the screen, while they show; and while they do not,
  /// the chip in the rack's corner that shows them.
  public var keyboard: RackKeys?
  public var keysChip: Chip?

  /// Under this many points across, a touchscreen's header is a phone's: the patch's name a chip
  /// beside the transport, and no room for what the keys play.
  public static let compactWidth: Float = 600
  /// Past fitting the width, how far a touchscreen zooms in: enough for a half-width module to fill
  /// a phone, and a knob on it to be a finger's size.
  public static let maxZoom: Float = 3
  /// How far from a control a finger may land and still take it, in points on the window: a
  /// finger's reach, whatever the zoom.
  public static let reach: Float = 22
  /// A touchscreen's rack is inset this far from the window's sides.
  public static let inset: Float = 8

  @MainActor
  /// `pages` is the bar each face with more than one shows, by module. `touch` lays the rack out for
  /// fingers, `zoom` past fitting the width and panned `pan` points from its left.
  public init(
    rack: RackSession, size: SIMD2<Float>, scroll: Float = 0, pages: [String: Int] = [:], touch: Bool = false,
    zoom: Float = 1, pan: Float = 0, keys showsKeys: Bool = false
  ) {
    self.size = size
    self.touch = touch
    let margin = Self.margin
    header = Rect(margin, margin, max(0, size.x - margin * 2), Self.headerHeight)
    let chipY = header.y + 8
    let chipHeight = header.height - 16
    if touch, size.x < Self.compactWidth {
      // A phone's: its name a chip at the left, then the transport, the tempo, the flip and ADD,
      // each as narrow as its label lets it be.
      let add = Rect(header.maxX - 6 - 44, chipY, 44, chipHeight)
      let flip = Rect(add.x - 4 - 58, chipY, 58, chipHeight)
      tempo = Rect(flip.x - 4 - 66, chipY, 66, chipHeight)
      let run = Rect(tempo.x - 4 - 52, chipY, 52, chipHeight)
      let name = Rect(header.x + 6, chipY, max(0, run.x - 6 - header.x - 6), chipHeight)
      keys = Rect(add.maxX, header.y, 0, 0)
      title = Rect(name.x, header.y, 0, 0)
      chips = [
        Chip(frame: name, label: rack.name, target: .patches, isOn: false),
        Chip(frame: run, label: rack.running ? "STOP" : "PLAY", target: .run, isOn: rack.running),
        Chip(frame: flip, label: rack.flipped ? "FRONT" : "BACK", target: .flip, isOn: rack.flipped),
        Chip(frame: add, label: "ADD", target: .add, isOn: false),
      ]
    } else {
      let add = Rect(header.maxX - 10 - 56, chipY, 56, chipHeight)
      let flip = Rect(add.x - 6 - 64, chipY, 64, chipHeight)
      keys = Rect(flip.x - 12 - 70, header.y, 70, header.height)
      tempo = Rect(keys.x - 8 - 76, chipY, 76, chipHeight)
      let run = Rect(tempo.x - 8 - 60, chipY, 60, chipHeight)
      chips = [
        Chip(frame: run, label: rack.running ? "STOP" : "PLAY", target: .run, isOn: rack.running),
        Chip(frame: flip, label: rack.flipped ? "FRONT" : "BACK", target: .flip, isOn: rack.flipped),
        Chip(frame: add, label: "ADD", target: .add, isOn: false),
      ]
      title = Rect(header.x + 14, header.y, max(0, run.x - 12 - header.x - 14), header.height)
      if touch {
        // On a tablet the name is where it is on a desktop, and a press on it is the patches.
        chips.insert(
          Chip(
            frame: Rect(title.x - 8, chipY, min(title.width, 260), chipHeight), label: rack.name,
            target: .patches, isOn: false), at: 0)
        title = Rect(title.x, header.y, 0, 0)
      }
    }

    // A Combinator's routing open beside the rack takes the right of the window, and the rack the rest.
    let combi = rack.editingRoutes.flatMap { id in rack.patch.modules.first { $0.id == id } }
    // On a phone the routing is a sheet across the foot, as the groovebox's knobs are, and the rack
    // keeps the whole width above it; elsewhere it is down the right, and the rack has the rest.
    let sheet = touch && size.x < Self.compactWidth
    let room = combi == nil || sheet ? size.x : max(0, size.x - Routing.width)
    let width = Float(RackLayout.width)
    // The keys, on a touchscreen, take the foot of the screen, and the rack the rest; a routing open
    // has it instead.
    keyboard = touch && showsKeys && combi == nil ? RackKeys(size: size, margin: margin) : nil
    var foot = keyboard.map { $0.frame.y - margin } ?? size.y
    var sheetFrame: Rect?
    if sheet, let combi {
      let height = min(size.y * 0.62, Routing.sheetHeight(for: combi, in: rack))
      let frame = Rect(margin, size.y - margin - height, max(0, size.x - margin * 2), height)
      sheetFrame = frame
      foot = frame.y - margin
    }
    area = Rect(0, header.maxY + margin, room, max(0, foot - header.maxY - margin))
    if touch, !showsKeys, combi == nil {
      keysChip = Chip(
        frame: Rect(area.maxX - margin - 64, area.maxY - margin - 32, 64, 32), label: "KEYS", target: .keys,
        isOn: false)
    }
    let beside =
      sheetFrame ?? Rect(room, area.y, max(0, size.x - room - margin), max(0, size.y - area.y - margin))
    routing = combi.map {
      Routing(combi: $0, rack: rack, frame: beside, touch: touch, sheet: sheetFrame != nil)
    }
    let layout = RackLayout.layout(rack.patch.modules)
    placements = layout.placements
    height = Float(max(layout.height, RackLayout.row))
    if touch {
      // Fitted to the width, but no larger than a desktop's, which a tablet on its side would take
      // it past; and zoomed from there by the fingers. Wider than the window, it is panned; narrower,
      // centred.
      let across = max(1, room - Self.inset * 2)
      fitScale = min(Self.largest, across / width)
      self.zoom = max(1, min(Self.maxZoom, zoom))
      scale = fitScale * self.zoom
      maxPan = max(0, width * scale - across)
      self.pan = min(max(0, pan), maxPan)
      maxScroll = max(0, (height + 24) * scale - area.height)
      self.scroll = min(max(0, scroll), maxScroll)
      let spare = max(0, across - width * scale)
      origin = SIMD2(Self.inset + spare / 2 - self.pan, area.y - self.scroll)
    } else {
      scale = max(0.5, min(Self.largest, (room - 48) / width))
      fitScale = scale
      maxScroll = max(0, (height + 24) * scale - area.height)
      self.scroll = min(max(0, scroll), maxScroll)
      origin = SIMD2((room - width * scale) / 2, area.y - self.scroll)
    }

    let modules = Dictionary(rack.patch.modules.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    faces = layout.placements.compactMap { placement in
      guard let module = modules[placement.id] else { return nil }
      return Self.face(module, placement, rack: rack, page: pages[module.id] ?? 0, touch: touch)
    }
  }

  /// A module's front: its panel, inset from its place; its title; and its controls, as its own
  /// hand-built face lays them out, or as the generic face does — a cell for every param a hand
  /// could set, three across on a half-width module and seven on a full one. `touch` words it for
  /// a finger.
  @MainActor
  static func face(
    _ module: PatchModule, _ placement: RackLayout.Placement, rack: RackSession, page: Int = 0,
    touch: Bool = false
  ) -> Face {
    let frame = Rect(
      Float(placement.x) + 3, Float(placement.y) + 3, Float(placement.width) - 6, Float(placement.height) - 6)
    let def = RackModules.registry[module.type]
    let title = Rect(frame.x + 12, frame.y + 10, frame.width - 24, Float(RackLayout.title) - 10)
    let top = title.maxY + 6
    guard let def else {
      return Face(
        module: module, def: nil, span: placement.span, frame: frame, title: title, words: "", controls: [])
    }
    if let built = RackFaces.face(module, def, frame: frame, top: top, rack: rack, page: page, touch: touch) {
      return Face(
        module: module, def: def, span: placement.span, frame: frame, title: title, words: built.words,
        wordsTint: built.wordsTint, wordsFont: built.wordsFont, controls: built.cells.controls,
        mark: built.mark,
        markTint: built.markTint, name: built.name, light: built.light,
        screen: built.screen, buttons: built.buttons, cells: built.dataCells)
    }
    var cells = RackFaces.Cells(
      def: def, x: frame.x + 12, top: top, columns: RackLayout.columns(for: placement.span))
    for param in def.params where !param.hidden { cells.add(param.id) }
    return Face(
      module: module, def: def, span: placement.span, frame: frame, title: title,
      words: RackLayout.portSummary(def), controls: cells.controls)
  }

  /// A knob for a range; buttons for a choice of up to three; a stepper for more — a choice is not a
  /// knob with positions, and twelve buttons would not fit a cell.
  static func kind(of param: ParamDef, in cell: Rect, diameter: Float = 34) -> Control.Kind {
    guard param.stepped else {
      return .knob(dial: Rect(cell.x + (cell.width - diameter) / 2, cell.y + 2, diameter, diameter))
    }
    let count = Int((param.max - param.min).rounded()) + 1
    if count <= 3 {
      let height: Float = 13
      let first = cell.y + (46 - Float(count) * (height + 2)) / 2
      return .options(
        (0..<count).map {
          // As wide as a cell of the usual size gives them, and centred in a wider one.
          let width = min(cell.width - 10, 48)
          return Rect(cell.x + (cell.width - width) / 2, first + Float($0) * (height + 2), width, height)
        })
    }
    return .stepper(
      value: Rect(cell.x + 2, cell.y + 6, cell.width - 4, 14),
      down: Rect(cell.x + cell.width / 2 - 23, cell.y + 24, 21, 16),
      up: Rect(cell.x + cell.width / 2 + 2, cell.y + 24, 21, 16))
  }

  /// A point on the window, in the rack's design space.
  public func design(_ point: SIMD2<Float>) -> SIMD2<Float> { (point - origin) / scale }

  /// What pressing at `point`, on the window, would do.
  public func target(at point: SIMD2<Float>) -> RackTarget? {
    if let part = routing?.part(at: point) { return .routing(part) }
    // On a touchscreen a chip in the header or over the keys is hit anywhere up and down its strip,
    // which is a finger's height where the chip is not.
    func hits(_ frame: Rect, along strip: Rect) -> Bool {
      touch ? Rect(frame.x, strip.y, frame.width, strip.height).contains(point) : frame.contains(point)
    }
    if let chip = chips.first(where: { hits($0.frame, along: header) }) { return chip.target }
    if hits(tempo, along: header) { return .tempo }
    if let keysChip, keysChip.frame.contains(point) { return .keys }
    if let keyboard, keyboard.frame.contains(point) {
      let row = Rect(keyboard.frame.x, keyboard.frame.y, keyboard.frame.width, RackKeys.rowHeight)
      if hits(keyboard.down, along: row) { return .octave(by: -1) }
      if hits(keyboard.up, along: row) { return .octave(by: 1) }
      if hits(keyboard.hide, along: row) { return .keys }
      return nil
    }
    guard area.contains(point) else { return nil }
    let at = design(point)
    guard let face = faces.first(where: { $0.frame.contains(at) }) else { return nil }
    let id = face.module.id
    if let index = face.buttons.firstIndex(where: { $0.frame.contains(at) }) {
      return .button(module: id, index: index)
    }
    if let index = face.cells.firstIndex(where: { $0.frame.contains(at) }) {
      return .cell(module: id, index: index)
    }
    // A module's head, its title across the top, is the module's, and reach takes nothing from it:
    // it is where a finger grabs a module to select it or fit it to the window.
    let head = Rect(face.frame.x, face.frame.y, face.frame.width, face.title.maxY + 6 - face.frame.y)
    if touch, !head.contains(at), let near = nearest(to: at, on: face) { return near }
    for control in face.controls where control.cell.contains(at) {
      let param = control.param.id
      switch control.kind {
      case .knob:
        return .knob(module: id, param: param)
      case .options(let buttons):
        if let index = buttons.firstIndex(where: { $0.contains(at) }) {
          return .option(module: id, param: param, value: Int(control.param.min) + index)
        }
      case .stepper(_, let down, let up):
        if down.contains(at) { return .step(module: id, param: param, by: -1) }
        if up.contains(at) { return .step(module: id, param: param, by: 1) }
      }
    }
    return .module(id)
  }

  /// On a touchscreen, whatever on `face` a finger landing at `at` means: the nearest of its buttons,
  /// numbers and controls within a finger's reach, however small the zoom draws them.
  func nearest(to at: SIMD2<Float>, on face: Face) -> RackTarget? {
    let reach = Self.reach / scale
    func distance(_ rect: Rect) -> Float {
      let dx = max(rect.x - at.x, 0, at.x - rect.maxX)
      let dy = max(rect.y - at.y, 0, at.y - rect.maxY)
      return (dx * dx + dy * dy).squareRoot()
    }
    var best: (target: RackTarget, distance: Float)?
    func offer(_ target: RackTarget, _ rect: Rect) {
      let d = distance(rect)
      if d <= reach, d < (best?.distance ?? .infinity) { best = (target, d) }
    }
    let id = face.module.id
    for (index, button) in face.buttons.enumerated() {
      offer(.button(module: id, index: index), button.frame)
    }
    for (index, cell) in face.cells.enumerated() { offer(.cell(module: id, index: index), cell.frame) }
    for control in face.controls {
      let param = control.param.id
      switch control.kind {
      case .knob(let dial):
        offer(.knob(module: id, param: param), dial)
      case .options(let buttons):
        for (index, button) in buttons.enumerated() {
          offer(.option(module: id, param: param, value: Int(control.param.min) + index), button)
        }
      case .stepper(_, let down, let up):
        offer(.step(module: id, param: param, by: -1), down)
        offer(.step(module: id, param: param, by: 1), up)
      }
    }
    return best?.target
  }

  /// The face at `point`, on the window, if there is one there.
  public func face(at point: SIMD2<Float>) -> Face? {
    guard area.contains(point) else { return nil }
    let at = design(point)
    return faces.first { $0.frame.contains(at) }
  }
}
