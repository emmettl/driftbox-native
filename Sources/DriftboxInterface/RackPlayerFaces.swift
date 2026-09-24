import DriftboxCanvas
import DriftboxRack
import DriftboxRackSession

/// The Chord Player's, the Arp's and the Combinator's faces, laid out as the Mac's are: the first
/// two show what they will play — the chord a setting voices, the figure an Arp walks — and the
/// Combinator what each of its controls drives.
extension RackFaces {
  static let chordKnobs = ["key", "scale", "notes", "inversion", "open", "octUp", "octDown", "color"]
  /// The Arp's controls, with shorter names where the whole would not fit a narrower cell.
  static let arpKnobs: [(id: String, name: String?)] = [
    ("enable", nil), ("source", nil), ("chord", nil), ("octaves", nil), ("mode", nil), ("gate", "Gate"),
    ("hold", nil), ("shift", "Shift"), ("velocityMode", "Vel"), ("velocity", "Fixed"), ("timing", nil),
    ("division", nil), ("rate", "Rate"), ("patternLength", "Steps"), ("insert", nil),
    ("singleRepeat", "Repeat"), ("shuffle", nil),
  ]
  static let arpSteps = 16
  static let combiControls = 4

  /// A selector's word for its setting, from a module's own labels.
  static func label(_ type: String, _ id: String, _ index: Int, _ fallback: String) -> String {
    ModuleFace.byType[type]?.labels[id].flatMap { index >= 0 && index < $0.count ? $0[index] : nil }
      ?? fallback
  }

  // MARK: The Chord Player

  /// The Chord Loom: the eight voices of the chord a setting makes, named, with an Alter button that
  /// holds while it is held.
  @MainActor
  static func chordPlayer(
    _ module: PatchModule, _ def: ModuleDef, x: Float, width: Float, top: Float, rack: RackSession
  ) -> Built {
    let value = { (id: String) in param(module, def, id, rack) }
    let key = max(0, min(11, Int(value("key").rounded())))
    let scale = max(0, min(13, Int(value("scale").rounded())))
    let notes = max(1, min(5, Int(value("notes").rounded())))
    let inversion = max(0, min(4, Int(value("inversion").rounded())))
    let altered = value("alter") >= 0.5
    let chord = RackPreview.chord(
      RackPreview.Chord(
        key: key, scale: scale, custom: module.data["customScale"] ?? [], notes: notes, inversion: inversion,
        open: value("open") >= 0.5, octUp: value("octUp") >= 0.5, octDown: value("octDown") >= 0.5,
        color: value("color") >= 0.5, alter: altered))

    let screen = Rect(x, top, width, 96)
    let voiceWidth = (width - 20 - 35) / 8
    var buttons = (0..<8).map { lane in
      let note = lane < chord.count ? chord[lane] : nil
      let octave = note.map { Int((Double($0 - key) / 12).rounded(.down)) }
      let badge = octave.map { $0 == 0 ? "root" : $0 > 0 ? "+\($0)×" : "\($0)×" } ?? "idle"
      return RackStage.Button(
        frame: Rect(x + 10 + Float(lane) * (voiceWidth + 5), top + 9, voiceWidth, 96 - 9 - 27),
        label: note.map { self.notes[(($0 % 12) + 12) % 12] } ?? "—", press: nil, isOn: note != nil,
        tint: Theme.three, style: .voice(lane: lane, badge: badge))
    }
    // Held and let go as one gesture, so a press is one step of undo, not two.
    buttons.append(
      RackStage.Button(
        frame: Rect(screen.midX - 25, screen.maxY - 4 - 18, 50, 18), label: "ALTER",
        press: .hold(param: "alter"), isOn: altered, tint: Theme.three, style: .capsule))
    var cells = Cells(
      def: def, x: x + (width - Float(RackLayout.cellWidth) * 4) / 2, top: screen.maxY + 6, columns: 4)
    for id in chordKnobs {
      cells.add(id, tint: id == "key" ? Theme.three : id == "scale" ? Theme.nine : nil)
    }
    let scaleName = label("chord-player", "scale", scale, "Scale \(scale + 1)")
    return Built(
      words: "\(self.notes[key]) \(scaleName) · \(chord.count) voices".uppercased(),
      wordsTint: Theme.three.faded(0.8), wordsFont: Theme.mono(8), cells: cells, mark: "CP—8",
      name: "Chord Loom", screen: screen, buttons: buttons)
  }

  // MARK: The Arp

  /// The Arp Field: sixteen rhythm steps, each showing the figure's note it would play — a click
  /// rests it — over every one of the Arp's controls.
  ///
  /// The Mac lays the controls out seven across, which takes three rows and runs out of the panel;
  /// here they are nine across in narrower cells, which is two, and fits.
  @MainActor
  static func arp(
    _ module: PatchModule, _ def: ModuleDef, x: Float, width: Float, top: Float, rack: RackSession
  ) -> Built {
    let value = { (id: String) in param(module, def, id, rack) }
    let source = max(0, min(1, Int(value("source").rounded())))
    let enabled = value("enable") >= 0.5
    let chord = max(0, min(7, Int(value("chord").rounded())))
    let mode = max(0, min(5, Int(value("mode").rounded())))
    let timing = max(0, min(2, Int(value("timing").rounded())))
    let division = max(0, min(15, Int(value("division").rounded())))
    let rate = max(0.1, min(250, value("rate")))
    let patternLength = max(1, min(arpSteps, Int(value("patternLength").rounded())))
    let insert = max(0, min(4, Int(value("insert").rounded())))
    let sourceName = label("arp", "source", source, source == 0 ? "Root" : "Played")
    let modeName = label("arp", "mode", mode, "Mode \(mode + 1)")
    let timingName =
      timing == 0
      ? "external clock"
      : timing == 1
        ? "\(label("arp", "division", division, "division \(division + 1)")) tempo"
          + (value("shuffle") >= 0.5 ? " · shuffle" : "")
        : (rate < 10 ? RackDisplay.fixed(rate, 1) : "\(Int(RackDisplay.jsRound(rate)))") + " Hz"
    let stored = module.data["pattern"] ?? []
    let pattern = (0..<arpSteps).map { $0 < stored.count ? stored[$0] : 1 }
    let figure = RackPreview.arp(
      source: source, chord: chord, octaves: Int(value("octaves").rounded()), mode: mode,
      shift: Int(value("shift").rounded()), insert: insert)
    // A rest holds the figure where it is: the next step on plays the note the rest would have.
    var at = 0
    let preview = pattern.map { on in
      let step = figure[min(figure.count - 1, at)]
      if on >= 0.5 { at += 1 }
      return step
    }
    let tint = source == 1 ? Theme.nine : Theme.violet

    let screen = Rect(x, top, width, 94)
    let stepWidth = (width - 20 - 3 * Float(arpSteps - 1)) / Float(arpSteps)
    let buttons = (0..<arpSteps).map { index in
      let on = pattern[index] >= 0.5
      let active = index < patternLength
      var next = pattern
      next[index] = on ? 0 : 1
      return RackStage.Button(
        frame: Rect(x + 10 + Float(index) * (stepWidth + 3), top + 10, stepWidth, 94 - 38),
        label: on ? preview[index].label : "—",
        press: active ? .data(slot: "pattern", values: next, name: "Edit Rhythm") : nil, isOn: on, tint: tint,
        style: .arpStep(number: index + 1, octave: preview[index].octave), opacity: active ? 1 : 0.28)
    }
    let narrow: Float = 50
    var cells = Cells(
      def: def, x: x + (width - narrow * 9) / 2, top: screen.maxY + 6, columns: 9, cellWidth: narrow)
    for (id, name) in arpKnobs {
      cells.add(
        id, tint: id == "source" || id == "hold" ? Theme.three : id == "mode" ? Theme.nine : nil, name: name)
    }
    return Built(
      words: (enabled ? "\(sourceName) · \(modeName) · \(timingName)" : "\(sourceName) · converter")
        .uppercased(),
      wordsTint: tint.faded(0.82), wordsFont: Theme.mono(8), cells: cells, mark: "AP—64", name: "Arp Field",
      screen: screen, buttons: buttons)
  }

  // MARK: The Combinator

  /// Whether a Combinator's control drives anything: routed to a param, or patched from its jack.
  @MainActor
  static func combiLive(_ module: String, _ id: String, rack: RackSession) -> Bool {
    rack.patch.modulation.contains { $0.from.module == module && $0.from.port == id }
      || rack.patch.cables.contains { $0.from.module == module && $0.from.port == id }
  }

  /// Four rotaries and four buttons, what each drives, and the whole routing, written out,
  /// underneath. Each rotary has its own MIDI learn.
  @MainActor
  static func combinator(
    _ module: PatchModule, _ def: ModuleDef, x: Float, width: Float, top: Float, bottom: Float,
    rack: RackSession
  ) -> Built {
    let routes = rack.patch.modulation.filter { $0.from.module == module.id }
    let left = x + 4
    let across = width - 8
    let column = across / Float(combiControls)
    var cells = Cells(def: def, x: left, top: top, columns: combiControls, cellWidth: column)
    var buttons: [RackStage.Button] = []
    let bindings = RackCC.bindings(rack.ccBindings, for: module.id)
    let chipY = top + Float(RackLayout.cellHeight) + 18
    for index in 1...combiControls {
      let id = "rotary\(index)"
      cells.add(
        id, tint: Theme.three, display: { "\(Int(RackDisplay.jsRound($0 / 127 * 100)))%" }, whole: true)
      let armed = rack.ccLearning == PortReference(module.id, id)
      let bound = bindings[id]
      let chip = min(column - 8, 84)
      buttons.append(
        RackStage.Button(
          frame: Rect(left + Float(index - 1) * column + (column - chip) / 2, chipY, chip, 13),
          label: armed ? "turn one…" : bound.map(RackCC.describe) ?? "learn", press: .learn(param: id),
          isOn: armed, tint: Theme.three, style: .learn(armed: armed, bound: bound != nil)))
    }
    let padY = chipY + 13 + 6
    let padWidth = (across - 24) / Float(combiControls)
    for index in 1...combiControls {
      let id = "button\(index)"
      let on = Int(param(module, def, id, rack).rounded()) == 1
      buttons.append(
        RackStage.Button(
          frame: Rect(left + Float(index - 1) * (padWidth + 8), padY, padWidth, 28), label: "\(index)",
          press: .set(param: id, value: on ? 0 : 1), isOn: on, tint: Theme.three,
          style: .pad(live: combiLive(module.id, id, rack: rack))))
    }
    let list = padY + 28 + 6
    // Under the routing written out, what edits it: open beside the rack, as on the Mac.
    let open = rack.editingRoutes == module.id
    buttons.append(
      RackStage.Button(
        frame: Rect(left, bottom - 16, 110, 16), label: open ? "Close Routing" : "Routing…", press: .routes,
        isOn: open, tint: Theme.nine, style: .option))
    return Built(
      words: routes.isEmpty ? "no routing" : "\(routes.count) routing\(routes.count == 1 ? "" : "s")",
      cells: cells, screen: Rect(left, list, across, max(0, bottom - 22 - list)), buttons: buttons)
  }
}
