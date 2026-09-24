import DriftboxCanvas
import DriftboxRack
import DriftboxRackSession

/// The faces that edit what a module plays rather than how: the Tracker's lanes, the Arranger's
/// song, the Scale Player's map and the Note Echo's pulses, as the Mac lays them out. All four write
/// the module's data, which reaches the sound on the next block while it plays; a drag is one step
/// of undo however far it goes.
extension RackFaces {
  static let trackerLanes = 4
  static let trackerPage = 16
  /// What a click writes into an empty step: a fifth above the root, or slice 7 of 16.
  static let trackerFresh = 7
  static let unitTags = ["S", "U", "C"]
  static let arrangerSections = 16
  /// The bars a fresh section lasts: a phrase.
  static let arrangerBars = 4
  static let notes = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
  static let blackKeys: Set<Int> = [1, 3, 6, 8, 10]
  static let customScale = 13
  static let echoSteps = 17
  static let echoKnobs = ["sync", "time", "division", "repeats", "pitch", "velocity", "gate", "dry"]

  /// The reference's `scalePlayerMask`: which of the twelve notes from the key a scale has, with an
  /// empty custom map falling back to major.
  static let presets: [[Int]] = [
    [0, 2, 4, 5, 7, 9, 11], [0, 2, 3, 5, 7, 8, 10], [0, 2, 4, 6, 7, 9, 11], [0, 2, 4, 5, 7, 9, 10],
    [0, 1, 4, 5, 7, 8, 10], [0, 2, 3, 5, 7, 9, 10], [0, 1, 3, 5, 7, 8, 10], [0, 2, 3, 5, 7, 8, 11],
    [0, 2, 3, 5, 7, 9, 11], [0, 2, 4, 7, 9], [0, 3, 5, 7, 10], [0, 1, 5, 7, 8],
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
  ]

  static func mask(_ scale: Int, _ custom: [Double]) -> [Double] {
    let which = max(0, min(13, scale))
    let degrees: [Int] =
      which < presets.count
      ? presets[which]
      : custom.contains(where: { $0 >= 0.5 }) ? custom.indices.filter { custom[$0] >= 0.5 } : presets[0]
    return (0..<12).map { degrees.contains($0) ? 1 : 0 }
  }

  /// A section's bars, as the arranger plays it.
  static func bars(_ repeats: [Double], _ at: Int) -> Int {
    max(1, Int(RackDisplay.jsRound(at < repeats.count ? repeats[at] : Double(arrangerBars))))
  }

  @MainActor
  static func param(_ module: PatchModule, _ def: ModuleDef, _ id: String, _ rack: RackSession) -> Double {
    def.params.first { $0.id == id }.map { rack.value(module, $0) } ?? 0
  }

  // MARK: The Tracker

  /// Four lanes of up to sixty-four steps, a bar at a time: click a step to set or clear it, drag it
  /// for its value. A lane's tag is its mode — Semitones, Units, or a Curve that goes negative — and
  /// a click moves it on.
  @MainActor
  static func tracker(
    _ module: PatchModule, _ def: ModuleDef, x: Float, width: Float, top: Float, bottom: Float,
    rack: RackSession, page: Int
  ) -> Built {
    let value = { (id: String) in param(module, def, id, rack) }
    let length = Int(value("length").rounded())
    let bank = Int(value("pattern").rounded())
    let pages = max(1, (length + trackerPage - 1) / trackerPage)
    let at = max(0, min(page, pages - 1))
    let steps = Array(at * trackerPage..<max(at * trackerPage, min(length, (at + 1) * trackerPage)))
    var cells = Cells(def: def, x: x, top: top, columns: 6)
    cells.add("length")
    cells.add("pattern")
    for lane in 1...trackerLanes { cells.add("mute\(lane)") }

    let left = x + 10
    let across = width - 20
    var y = top + Float(RackLayout.cellHeight) + 6
    var buttons: [RackStage.Button] = []
    if pages > 1 {
      for index in 0..<pages {
        buttons.append(
          RackStage.Button(
            frame: Rect(left + Float(index) * 25, y, 22, 13), label: "\(index + 1)", press: .page(index),
            isOn: index == at, tint: Theme.nine, style: .option))
      }
      y += 17
    }
    var data: [RackStage.Cell] = []
    let base = bank * length
    let count = max(1, steps.count)
    let cellWidth = (across - 20 - 2 * Float(count)) / Float(count)
    for lane in 0..<trackerLanes {
      let rowY = y + Float(lane) * 50
      let values = module.data["lane\(lane + 1)"] ?? []
      let mode = max(0, min(2, Int(value("unit\(lane + 1)").rounded())))
      let muted = Int(value("mute\(lane + 1)").rounded()) == 1
      buttons.append(
        RackStage.Button(
          frame: Rect(left, rowY, 20, 46), label: "\(unitTags[mode])\(lane + 1)",
          press: .set(param: "unit\(lane + 1)", value: Double((mode + 1) % 3)), isOn: false, tint: Theme.dim,
          style: .tag, opacity: muted ? 0.35 : 1))
      for (index, step) in steps.enumerated() {
        let held = base + step < values.count ? Int(values[base + step].rounded()) : 0
        var cell = RackStage.Cell(
          frame: Rect(left + 22 + Float(index) * (cellWidth + 2), rowY, cellWidth, 46), value: held,
          range: (mode == 2 ? -48 : 0)...48, slot: "lane\(lane + 1)", index: base + step,
          padTo: base + length,
          pad: 0, name: "Edit Step", click: nil, isStep: true, accent: step % 4 == 0,
          opacity: muted ? 0.35 : 1)
        cell.click = .data(
          slot: cell.slot, values: cell.written(held != 0 ? 0 : trackerFresh, in: values), name: cell.name)
        data.append(cell)
      }
    }
    return Built(
      words: "P\(bank + 1) · \(length) steps" + (pages > 1 ? " · bar \(at + 1)/\(pages)" : ""), cells: cells,
      buttons: buttons, dataCells: data)
  }

  // MARK: The Arranger

  /// Sixteen sections of a song in two columns: which pattern each plays and for how many bars.
  /// Drag either number; click a pattern to step it on.
  @MainActor
  static func arranger(
    _ module: PatchModule, _ def: ModuleDef, x: Float, width: Float, top: Float, bottom: Float,
    rack: RackSession
  ) -> Built {
    let length = Int(param(module, def, "length", rack).rounded())
    let patterns = module.data["patterns"] ?? []
    let repeats = module.data["repeats"] ?? []
    let total = (0..<max(0, length)).reduce(0) { $0 + bars(repeats, $1) }
    var cells = Cells(def: def, x: x, top: top, columns: 1)
    cells.add("length")

    let left = x + 10
    let y = top + Float(RackLayout.cellHeight) + 6
    let columnWidth = (width - 20 - 10) / 2
    let rows = arrangerSections / 2
    // The heading, then the rows sharing what is left.
    let rowHeight = max(12, (bottom - 10 - y - 12 - Float(rows - 1) * 2) / Float(rows))
    let cellWidth = (columnWidth - 14 - 6) / 2
    var data: [RackStage.Cell] = []
    for at in 0..<arrangerSections {
      let column = Float(at / rows)
      let rowY = y + 12 + Float(at % rows) * (rowHeight + 2)
      let cellX = left + column * (columnWidth + 10) + 17
      let pattern = at < patterns.count ? Int(RackDisplay.jsRound(patterns[at])) : 0
      let opacity: Float = at < length ? 1 : 0.3
      var cell = RackStage.Cell(
        frame: Rect(cellX, rowY, cellWidth, rowHeight), value: pattern, range: 0...7, slot: "patterns",
        index: at, padTo: arrangerSections, pad: 0, name: "Edit Song", click: nil, opacity: opacity)
      cell.click = .data(
        slot: "patterns", values: cell.written(pattern >= 7 ? 0 : pattern + 1, in: patterns),
        name: "Edit Song")
      data.append(cell)
      data.append(
        RackStage.Cell(
          frame: Rect(cellX + cellWidth + 3, rowY, cellWidth, rowHeight), value: bars(repeats, at),
          range: 1...64, slot: "repeats", index: at, padTo: arrangerSections, pad: Double(arrangerBars),
          name: "Edit Song", click: nil, opacity: opacity))
    }
    return Built(words: "\(total) bars", cells: cells, dataCells: data)
  }

  // MARK: The Scale Player

  /// The twelve notes of the scale, from its key: lit when in it. A click takes the map to Custom
  /// and toggles the note — never the last one out.
  @MainActor
  static func scalePlayer(
    _ module: PatchModule, _ def: ModuleDef, x: Float, width: Float, top: Float, rack: RackSession
  ) -> Built {
    let value = { (id: String) in param(module, def, id, rack) }
    let key = max(0, min(11, Int(value("key").rounded())))
    let scale = max(0, min(13, Int(value("scale").rounded())))
    let filtering = Int(value("filter").rounded()) == 1
    let mask = mask(scale, module.data["customScale"] ?? [])
    let count = mask.filter { $0 >= 0.5 }.count
    let names = ModuleFace.byType["scale-player"]?.labels["scale"]
    let name = names.flatMap { scale < $0.count ? $0[scale] : nil } ?? "Scale \(scale + 1)"

    let screen = Rect(x, top, width, 92)
    let keyWidth = (width - 20 - 33) / 12
    let buttons = (0..<12).map { relative in
      let actual = (key + relative) % 12
      let black = blackKeys.contains(actual)
      let on = mask[relative] >= 0.5
      var next = mask
      next[relative] = on ? 0 : 1
      return RackStage.Button(
        frame: Rect(x + 10 + Float(relative) * (keyWidth + 3), top + 9, keyWidth, black ? 42 : 57),
        label: notes[actual],
        press: on && count <= 1
          ? nil
          : .data(
            slot: "customScale", values: next, name: "Edit Scale", then: scale != customScale ? "scale" : nil,
            to: Double(customScale)),
        isOn: on, tint: black ? Theme.three : Theme.violet, style: .key(black: black, root: relative == 0))
    }
    var cells = Cells(
      def: def, x: x + (width - Float(RackLayout.cellWidth) * 3) / 2, top: screen.maxY + 6, columns: 3)
    cells.add("key", tint: Theme.three)
    cells.add("scale", tint: Theme.nine)
    cells.add("filter")
    return Built(
      words: "\(notes[key]) \(name) · \(filtering ? "filter" : "correct")", cells: cells, mark: "SP—13",
      name: "Scale Map",
      markTint: Theme.violet, screen: screen, buttons: buttons)
  }

  // MARK: The Note Echo

  /// The dry note and sixteen repeats as pulses, as tall as their velocity; the ones past the repeat
  /// count asleep; a click mutes or unmutes one.
  @MainActor
  static func noteEcho(
    _ module: PatchModule, _ def: ModuleDef, x: Float, width: Float, top: Float, rack: RackSession
  ) -> Built {
    let value = { (id: String) in param(module, def, id, rack) }
    let repeats = max(1, min(16, Int(value("repeats").rounded())))
    let velocity = value("velocity")
    let sync = Int(value("sync").rounded()) == 1
    let division = max(0, min(7, Int(value("division").rounded())))
    let stored = module.data["steps"] ?? []
    let steps = (0..<echoSteps).map { $0 < stored.count ? stored[$0] : 1 }
    let divisions = ModuleFace.byType["note-echo"]?.labels["division"]
    let interval =
      sync
      ? divisions.flatMap { division < $0.count ? $0[division] : nil } ?? "step \(division + 1)"
      : "\(Int(value("time").rounded()))ms"

    let screen = Rect(x, top, width, 106)
    let pulseWidth = (width - 18 - 2 * Float(echoSteps - 1)) / Float(echoSteps)
    let buttons = (0..<echoSteps).map { index in
      let amount = index == 0 ? 1 : max(0, min(1, 1 + (velocity - 1) * Double(index)))
      let on = steps[index] >= 0.5
      let active = index <= repeats
      var next = steps
      next[index] = on ? 0 : 1
      return RackStage.Button(
        frame: Rect(x + 9 + Float(index) * (pulseWidth + 2), screen.maxY - 23 - 66, pulseWidth, 66),
        label: index == 0 ? "D" : "\(index)",
        press: active ? .data(slot: "steps", values: next, name: "Edit Echoes") : nil, isOn: on && active,
        tint: Theme.three, style: .pulse(amount: amount), opacity: active ? 1 : 0.22)
    }
    var cells = Cells(
      def: def, x: x + (width - Float(RackLayout.cellWidth) * 4) / 2, top: screen.maxY + 6, columns: 4)
    for id in echoKnobs {
      cells.add(id, tint: id == "pitch" ? Theme.three : id == "velocity" ? Theme.nine : nil)
    }
    return Built(
      words: "\(repeats) repeats · \(interval)", cells: cells, mark: "NE—16", name: "Echo Matrix",
      screen: screen, buttons: buttons)
  }
}
