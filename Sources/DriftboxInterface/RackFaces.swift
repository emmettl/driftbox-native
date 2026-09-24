import DriftboxCanvas
import DriftboxRack
import DriftboxRackSession

/// The faces the reference builds by hand, laid out as the Mac's are: each says something the
/// definition cannot — which knob matters, what a setting is doing, what is coming in.
///
/// A hand-built face names its params rather than walking them, which is the point of building one
/// and also its hazard: a param added to the module does not appear. So `shows` says what each
/// shows, and the tests hold that to what it lays out.
public enum RackFaces {
  public static let shows: [String: Set<String>] = [
    "vco": ["tune", "shape", "width"],
    "ladder": ["cutoff", "resonance"],
    "out": ["level", "pan", "mute", "solo"],
    "midi": Set(RackModules.registry["midi"]?.params.filter { !$0.hidden }.map(\.id) ?? []),
  ]

  static let shapes = ["Saw", "Pulse", "Tri"]

  /// A face's controls in cells of the usual size, left to right from its top and `columns` across;
  /// a larger knob makes its row taller.
  struct Cells {
    let def: ModuleDef
    let x: Float
    let top: Float
    let columns: Int
    private(set) var controls: [RackStage.Control] = []
    private var column = 0
    private var y: Float
    private var rowHeight: Float = 0

    init(def: ModuleDef, x: Float, top: Float, columns: Int) {
      self.def = def
      self.x = x
      self.top = top
      self.columns = max(1, columns)
      y = top
    }

    /// The control for the param `id`, in the next cell. `name` is a shorter name under it, where
    /// the face already says whose control it is.
    mutating func add(
      _ id: String, tint: Colour? = nil, diameter: Float = 34, labels: [String]? = nil, name: String? = nil,
      opacity: Float = 1
    ) {
      guard let param = def.params.first(where: { $0.id == id }) else { return }
      if column == columns {
        y += rowHeight
        column = 0
        rowHeight = 0
      }
      let width = Float(RackLayout.cellWidth)
      let height = max(Float(RackLayout.cellHeight), diameter + 28)
      let cell = Rect(x + Float(column) * width, y, width, height)
      controls.append(
        RackStage.Control(
          param: param, cell: cell, kind: RackStage.kind(of: param, in: cell, diameter: diameter), tint: tint,
          name: name, labels: labels, opacity: opacity))
      column += 1
      rowHeight = max(rowHeight, height)
    }
  }

  struct Built {
    var words: String
    var wordsTint: Colour?
    var cells: Cells
  }

  /// The face `def`'s module has of its own, from `x` and `top` on its panel; nil for the generic.
  @MainActor
  static func face(_ module: PatchModule, _ def: ModuleDef, x: Float, top: Float, rack: RackSession) -> Built?
  {
    func value(_ id: String) -> Double {
      def.params.first { $0.id == id }.map { rack.value(module, $0) } ?? 0
    }
    var cells = Cells(def: def, x: x, top: top, columns: 3)
    switch def.type {
    case "vco":
      // The tune knob big, because it is the one reached for; the shape named in the title; and
      // the pulse width asleep when the shape is not a pulse.
      let shape = Int(value("shape").rounded())
      cells.add("tune", tint: Theme.three, diameter: 46)
      cells.add("shape")
      cells.add("width", tint: Theme.three, opacity: shape == 1 ? 1 : 0.35)
      return Built(words: shapes.indices.contains(shape) ? shapes[shape] : "—", cells: cells)
    case "ladder":
      // The 303's filter, whose resonance turns pink where it starts to sing on its own.
      let squelch = value("resonance") > 0.75
      cells.add("cutoff", tint: Theme.three)
      cells.add("resonance", tint: squelch ? Theme.eight : Theme.three)
      return Built(words: squelch ? "squelch" : "4-pole", cells: cells)
    case "out":
      // A channel strip.
      cells.add("level", tint: Theme.nine)
      cells.add("pan", tint: Theme.eight)
      cells.add("mute")
      cells.add("solo")
      return Built(words: "", cells: cells)
    case "midi":
      // The keyboard's module, and the answer to the first question anybody asks of one: is
      // anything coming in? The last note played, or where the notes come from.
      cells = Cells(def: def, x: x, top: top, columns: def.params.count)
      for param in def.params where !param.hidden {
        cells.add(
          param.id, tint: param.id == "transpose" ? Theme.eight : nil,
          labels: param.id == "channel" ? ["Omni"] + (1...16).map(String.init) : nil)
      }
      return Built(
        words: rack.lastNote.map(RackKeyboard.name) ?? (rack.midiSources.isEmpty ? "keys" : "listening"),
        wordsTint: rack.lastNote == nil ? nil : Theme.nine, cells: cells)
    default:
      return nil
    }
  }
}
