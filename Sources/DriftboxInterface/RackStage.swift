import DriftboxCanvas
import DriftboxRack
import DriftboxRackSession

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
}

/// Where everything on the rack is, for a window `size` points across: the header in points, and
/// the rack under it in the rack's own design space — `RackLayout`'s, the reference's — drawn at
/// `scale` from `origin`, so that a face is laid out once in the units every face is designed in.
public struct RackStage {
  public static let margin: Float = 12
  public static let headerHeight: Float = 44

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
  }

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
    public var controls: [Control]
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

  @MainActor
  public init(rack: RackSession, size: SIMD2<Float>, scroll: Float = 0) {
    self.size = size
    let margin = Self.margin
    header = Rect(margin, margin, max(0, size.x - margin * 2), Self.headerHeight)
    let chipY = header.y + 8
    let chipHeight = header.height - 16
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

    // About the reference's size, a little larger when there is room: past this the panels stop
    // reading as a rack of modules and start reading as a poster of one.
    let width = Float(RackLayout.width)
    scale = max(0.5, min(1.35, (size.x - 48) / width))
    area = Rect(0, header.maxY + margin, size.x, max(0, size.y - header.maxY - margin))
    let layout = RackLayout.layout(rack.patch.modules)
    placements = layout.placements
    height = Float(max(layout.height, RackLayout.row))
    maxScroll = max(0, (height + 24) * scale - area.height)
    self.scroll = min(max(0, scroll), maxScroll)
    origin = SIMD2((size.x - width * scale) / 2, area.y - self.scroll)

    let modules = Dictionary(rack.patch.modules.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    faces = layout.placements.compactMap { placement in
      guard let module = modules[placement.id] else { return nil }
      return Self.face(module, placement, rack: rack)
    }
  }

  /// A module's front: its panel, inset from its place; its title; and its controls, as its own
  /// hand-built face lays them out, or as the generic face does — a cell for every param a hand
  /// could set, three across on a half-width module and seven on a full one.
  @MainActor
  static func face(_ module: PatchModule, _ placement: RackLayout.Placement, rack: RackSession) -> Face {
    let frame = Rect(
      Float(placement.x) + 3, Float(placement.y) + 3, Float(placement.width) - 6, Float(placement.height) - 6)
    let def = RackModules.registry[module.type]
    let title = Rect(frame.x + 12, frame.y + 10, frame.width - 24, Float(RackLayout.title) - 10)
    let top = title.maxY + 6
    guard let def else {
      return Face(
        module: module, def: nil, span: placement.span, frame: frame, title: title, words: "", controls: [])
    }
    if let built = RackFaces.face(module, def, x: frame.x + 12, top: top, rack: rack) {
      return Face(
        module: module, def: def, span: placement.span, frame: frame, title: title, words: built.words,
        wordsTint: built.wordsTint, controls: built.cells.controls)
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
        (0..<count).map { Rect(cell.x + 5, first + Float($0) * (height + 2), cell.width - 10, height) })
    }
    return .stepper(
      value: Rect(cell.x + 2, cell.y + 6, cell.width - 4, 14),
      down: Rect(cell.x + 6, cell.y + 24, 21, 16), up: Rect(cell.x + 31, cell.y + 24, 21, 16))
  }

  /// A point on the window, in the rack's design space.
  public func design(_ point: SIMD2<Float>) -> SIMD2<Float> { (point - origin) / scale }

  /// What pressing at `point`, on the window, would do.
  public func target(at point: SIMD2<Float>) -> RackTarget? {
    if let chip = chips.first(where: { $0.frame.contains(point) }) { return chip.target }
    if tempo.contains(point) { return .tempo }
    guard area.contains(point) else { return nil }
    let at = design(point)
    guard let face = faces.first(where: { $0.frame.contains(at) }) else { return nil }
    let id = face.module.id
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

  /// The face at `point`, on the window, if there is one there.
  public func face(at point: SIMD2<Float>) -> Face? {
    guard area.contains(point) else { return nil }
    let at = design(point)
    return faces.first { $0.frame.contains(at) }
  }
}
