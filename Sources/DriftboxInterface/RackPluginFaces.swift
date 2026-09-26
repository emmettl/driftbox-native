import DriftboxCanvas
import DriftboxRack
import DriftboxRackSession

/// The plug-in modules' front, as the Mac's is: which plug-in it hosts and by whom, how late it is
/// or why it is silent, a menu of the others of its kind to choose from, and its four macros, each
/// named for the param it turns and saying its value in that param's words. An instrument's has
/// the notes it is playing lit on two octaves of keys.
extension RackFaces {
  /// How tall the name and what is said under it are, and the buttons' row under them.
  static let pluginText: Float = 62
  static let pluginRow: Float = 16

  /// Where an instrument's keys are, from the top of its face's screen to the foot of its panel,
  /// with a line under them for the notes' names.
  static func pluginKeys(_ screen: Rect, frame: Rect) -> Rect {
    let top = screen.y + pluginText + 8 + pluginRow + 12
    return Rect(frame.x + 12, top, frame.width - 24, max(0, frame.maxY - 10 - 14 - top))
  }

  @MainActor
  static func plugin(
    _ module: PatchModule, _ def: ModuleDef, x: Float, width: Float, top: Float, rack: RackSession
  ) -> Built {
    let reference = module.plugin
    let status = rack.plugins[module.id]
    let running = if case .ready = status { true } else { false }
    let instrument = def.type == "plugin-instrument"
    let macros = Float(RackLayout.cellWidth) * 4
    var cells = Cells(def: def, x: x + width - macros, top: top, columns: 4)
    let unit = HeldUnit(unit: rack.units[module.id])
    for macro in 1...4 {
      let mapped = rack.macroParameter(module.id, macro)
      let key = mapped?.control.key
      cells.add(
        "macro\(macro)", tint: Theme.nine, name: mapped?.control.name ?? "Macro \(macro)",
        opacity: mapped == nil ? 0.5 : 1, display: key.map { words(unit, key: $0) })
    }
    let screen = Rect(x, top, max(0, width - macros - 10), pluginText)
    let row = screen.maxY + 8
    var buttons = [
      RackStage.Button(
        frame: Rect(x, row, 70, pluginRow), label: reference == nil ? "Choose…" : "Change…",
        press: rack.hostsPlugins ? .plugin : nil, isOn: reference == nil, tint: Theme.nine, style: .option,
        opacity: rack.hostsPlugins ? 1 : 0.4)
    ]
    // Only a plug-in that is running has params to map.
    if running {
      buttons.append(
        RackStage.Button(
          frame: Rect(x + 76, row, 50, pluginRow), label: "Map…", press: .macros, isOn: false,
          tint: Theme.nine,
          style: .option))
    }
    return Built(
      words: state(status, chosen: reference != nil), cells: cells, mark: mark(reference),
      name: instrument ? "Instrument" : "Plug-in", light: running, screen: screen, buttons: buttons)
  }

  /// A macro's value in the words of the param it turns, or as a percentage where the plug-in
  /// has none.
  static func words(_ unit: HeldUnit, key: String) -> @Sendable (Double) -> String {
    { fraction in
      let said = MainActor.assumeIsolated { unit.unit?.display(key, at: fraction) }
      return said ?? RackDisplay.fixed(fraction * 100, 0) + "%"
    }
  }

  /// The unit a knob's words come from, held for a closure that has to be `Sendable` to be kept:
  /// only ever called on the main actor, by the knob that shows it.
  struct HeldUnit: @unchecked Sendable {
    let unit: (any RackPluginUnit)?
  }

  /// The format, as the title marks it.
  static func mark(_ reference: PluginReference?) -> String? {
    switch reference?.format {
    case "vst3": "VST3"
    case "audio-unit": "AU"
    default: nil
    }
  }

  /// What the title says of it.
  static func state(_ status: RackSession.PluginStatus?, chosen: Bool) -> String {
    switch status {
    case nil: chosen ? "" : "empty"
    case .loading: "loading"
    case .ready: "running"
    case .missing: "missing"
    case .failed: "failed"
    }
  }

  /// Under the name: who made it and how late it is, or why it is silent.
  static func detail(_ reference: PluginReference?, _ status: RackSession.PluginStatus?, instrument: Bool)
    -> String
  {
    guard let reference else {
      return instrument ? "A plug-in instrument, played by the rack's notes" : "A plug-in effect, in stereo"
    }
    switch status {
    case .ready(let latency) where latency > 0:
      return "\(reference.vendor) · \(RackDisplay.fixed(latency * 1000, 1)) ms late"
    case .missing:
      return "Not on this machine. Kept in the patch, silent here."
    case .failed(let reason):
      return reason
    default:
      return reference.vendor
    }
  }
}

extension RackInterface {
  /// The plug-in's name and what is said of it; and an instrument's keys, the notes it is playing
  /// lit, from the C at or below the lowest, or C3 while nothing sounds, so a chord stays put.
  func drawPluginScreen(_ screen: Rect, face: RackStage.Face, on canvas: Canvas) {
    let reference = face.module.plugin
    let instrument = face.module.type == "plugin-instrument"
    canvas.align = .left
    canvas.font = Theme.mono(12, weight: 600)
    canvas.fill = Theme.ink
    canvas.fillText(
      fitted(reference?.name ?? "No plug-in", width: screen.width, on: canvas), screen.x, screen.y + 14)
    canvas.font = Theme.mono(8.5)
    canvas.fill = Theme.ink.faded(0.55)
    let detail = RackFaces.detail(reference, rack.plugins[face.module.id], instrument: instrument)
    for (index, line) in lines(detail, width: screen.width, on: canvas).prefix(3).enumerated() {
      canvas.fillText(line, screen.x, screen.y + 30 + Float(index) * 11)
    }
    guard instrument else { return }
    let keys = RackFaces.pluginKeys(screen, frame: face.frame)
    let notes = rack.readings[face.module.id]?.notes ?? []
    drawNoteStrip(keys, notes: notes, on: canvas)
    canvas.font = Theme.mono(8.5)
    canvas.fill = Theme.nine
    canvas.fillText(notes.map(RackKeyboard.name).joined(separator: " "), keys.x, keys.maxY + 11)
  }

  /// Two octaves of keys, `notes` lit.
  func drawNoteStrip(_ r: Rect, notes: [Int], on canvas: Canvas) {
    let low = notes.first.map { max(0, min(103, $0 - $0 % 12)) } ?? 48
    let sounding = Set(notes)
    let blacks: Set<Int> = [1, 3, 6, 8, 10]
    let whites = (low..<low + 24).filter { !blacks.contains($0 % 12) }
    let width = r.width / Float(whites.count)
    for (index, note) in whites.enumerated() {
      canvas.fill = sounding.contains(note) ? Theme.nine : Theme.ink.faded(0.82)
      canvas.fillRoundedRect(r.x + Float(index) * width, r.y, width - 1.5, r.height, radius: 2)
    }
    for (index, note) in whites.enumerated() where blacks.contains((note + 1) % 12) && note + 1 < low + 24 {
      canvas.fill = sounding.contains(note + 1) ? Theme.nine : Theme.ground
      canvas.fillRoundedRect(
        r.x + Float(index + 1) * width - width * 0.3 - 0.75, r.y, width * 0.6, r.height * 0.6, radius: 1.5)
    }
  }

  /// `text` cut to `width` in the canvas's font, with an ellipsis where it was cut.
  func fitted(_ text: String, width: Float, on canvas: Canvas) -> String {
    guard canvas.measure(text) > width else { return text }
    var cut = text
    while !cut.isEmpty && canvas.measure(cut + "…") > width { cut.removeLast() }
    return cut + "…"
  }

  /// `text` broken at its spaces into lines no wider than `width` in the canvas's font.
  func lines(_ text: String, width: Float, on canvas: Canvas) -> [String] {
    var lines: [String] = []
    var line = ""
    for word in text.split(separator: " ") {
      let next = line.isEmpty ? String(word) : line + " " + word
      if canvas.measure(next) > width, !line.isEmpty {
        lines.append(line)
        line = String(word)
      } else {
        line = next
      }
    }
    if !line.isEmpty { lines.append(line) }
    return lines
  }
}
