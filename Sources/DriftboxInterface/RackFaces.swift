import DriftboxCanvas
import DriftboxRack
import DriftboxRackSession
import DriftboxText

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
    "tuner": ["reference", "mute"],
    "meter": ["mode", "gain", "release"],
    "looper": ["mode", "clear", "feedback", "dry", "loop"],
    "tracker": Set(["length", "pattern"] + (1...4).flatMap { ["mute\($0)", "unit\($0)"] }),
    "arranger": ["length"],
    "scale-player": ["key", "scale", "filter"],
    "note-echo": Set(echoKnobs),
    "chord-player": Set(chordKnobs + ["alter"]),
    "arp": Set(arpKnobs.map(\.id)),
    "combi": Set((1...4).flatMap { ["rotary\($0)", "button\($0)"] }),
  ]

  static let shapes = ["Saw", "Pulse", "Tri"]
  static let loopModes = ["STOP", "REC", "PLAY", "DUB"]

  /// A face's controls in cells of the usual size, left to right from its top and `columns` across;
  /// a larger knob makes its row taller.
  struct Cells {
    let def: ModuleDef
    let x: Float
    let top: Float
    let columns: Int
    let cellWidth: Float
    private(set) var controls: [RackStage.Control] = []
    private var column = 0
    private var y: Float
    private var rowHeight: Float = 0

    init(def: ModuleDef, x: Float, top: Float, columns: Int, cellWidth: Float = Float(RackLayout.cellWidth)) {
      self.def = def
      self.cellWidth = cellWidth
      self.x = x
      self.top = top
      self.columns = max(1, columns)
      y = top
    }

    /// The control for the param `id`, in the next cell. `name` is a shorter name under it, where
    /// the face already says whose control it is.
    mutating func add(
      _ id: String, tint: Colour? = nil, diameter: Float = 34, labels: [String]? = nil, name: String? = nil,
      opacity: Float = 1, display: (@Sendable (Double) -> String)? = nil, whole: Bool = false
    ) {
      guard let param = def.params.first(where: { $0.id == id }) else { return }
      if column == columns {
        y += rowHeight
        column = 0
        rowHeight = 0
      }
      let width = cellWidth
      let height = max(Float(RackLayout.cellHeight), diameter + 28)
      let cell = Rect(x + Float(column) * width, y, width, height)
      controls.append(
        RackStage.Control(
          param: param, cell: cell, kind: RackStage.kind(of: param, in: cell, diameter: diameter), tint: tint,
          name: name, labels: labels, opacity: opacity, display: display, whole: whole))
      column += 1
      rowHeight = max(rowHeight, height)
    }
  }

  struct Built {
    var words: String
    var wordsTint: Colour?
    var wordsFont: FontRequest?
    var cells: Cells
    var mark: String?
    var name: String?
    var markTint: Colour?
    var screen: Rect?
    var buttons: [RackStage.Button] = []
    var dataCells: [RackStage.Cell] = []
  }

  /// The face `def`'s module has of its own, on its panel `frame` from `top` down, showing bar `page`
  /// where it has more than one; nil for the generic.
  @MainActor
  static func face(
    _ module: PatchModule, _ def: ModuleDef, frame: Rect, top: Float, rack: RackSession, page: Int = 0
  ) -> Built? {
    // Inside the panel's padding, as the Mac's faces sit in theirs.
    let x = frame.x + 12
    let width = frame.width - 24
    let bottom = frame.maxY - 10
    let cellWidth = Float(RackLayout.cellWidth)
    let cellHeight = Float(RackLayout.cellHeight)
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
    case "tuner":
      // The chromatic tuner: its display over its two controls.
      cells = Cells(def: def, x: x, top: bottom - cellHeight, columns: 2)
      cells.add("reference", tint: Theme.nine)
      cells.add("mute")
      return Built(
        words: "55–2000 Hz", cells: cells, mark: "CT—40", markTint: Theme.nine,
        screen: Rect(x, top, width, max(0, bottom - cellHeight - 6 - top)))
    case "meter":
      // A meter in a cable: its needle, lights or scope, and the three controls beside it.
      let controls = cellWidth * 3
      cells = Cells(def: def, x: x + width - controls, top: top + (bottom - top - cellHeight) / 2, columns: 3)
      cells.add("mode")
      cells.add("gain", tint: Theme.nine)
      cells.add("release", tint: Theme.three)
      let reading = rack.readings[module.id]
      return Built(
        words: RackDisplay.meterLabel(reading?.level ?? 0), cells: cells, mark: "VU—3", name: "Signal Bureau",
        screen: Rect(x, top, max(0, width - controls - 10), bottom - top))
    case "looper":
      // The loop station: what is in the loop, its transport, and its mix.
      let controls = cellWidth * 3
      let transport: Float = 168
      cells = Cells(def: def, x: x + width - controls, top: top + (bottom - top - cellHeight) / 2, columns: 3)
      cells.add("feedback", tint: Theme.three)
      cells.add("dry")
      cells.add("loop", tint: Theme.nine)
      let left = x + width - controls - 9 - transport
      let mode = Int(value("mode").rounded())
      let rowHeight = (bottom - top - 8) / 3
      let buttonWidth = (transport - 4) / 2
      var buttons = loopModes.indices.map { index in
        RackStage.Button(
          frame: Rect(
            left + Float(index % 2) * (buttonWidth + 4), top + Float(index / 2) * (rowHeight + 4),
            buttonWidth,
            rowHeight),
          label: loopModes[index], press: .set(param: "mode", value: Double(index)), isOn: mode == index,
          tint: index == 1 || index == 3 ? Theme.eight : Theme.nine)
      }
      // Clear is pressed, not held: each press turns the param over, and the looper hears the turn.
      buttons.append(
        RackStage.Button(
          frame: Rect(left, top + (rowHeight + 4) * 2, transport, rowHeight), label: "CLEAR",
          press: .set(param: "clear", value: value("clear") >= 0.5 ? 0 : 1), isOn: false, tint: Theme.eight,
          text: Theme.eight.faded(0.7)))
      return Built(
        words: "stereo · session", cells: cells, mark: "LS—30",
        screen: Rect(x, top, max(0, left - 9 - x), bottom - top), buttons: buttons)
    case "tracker":
      return tracker(module, def, x: x, width: width, top: top, bottom: bottom, rack: rack, page: page)
    case "arranger":
      return arranger(module, def, x: x, width: width, top: top, bottom: bottom, rack: rack)
    case "scale-player":
      return scalePlayer(module, def, x: x, width: width, top: top, rack: rack)
    case "note-echo":
      return noteEcho(module, def, x: x, width: width, top: top, rack: rack)
    case "chord-player":
      return chordPlayer(module, def, x: x, width: width, top: top, rack: rack)
    case "arp":
      return arp(module, def, x: x, width: width, top: top, rack: rack)
    case "combi":
      return combinator(module, def, x: x, width: width, top: top, bottom: bottom, rack: rack)
    default:
      return nil
    }
  }
}
