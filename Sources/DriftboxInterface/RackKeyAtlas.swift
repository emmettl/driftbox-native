import DriftboxCanvas
import DriftboxRack
import DriftboxRackSession

/// The Key Atlas, the Multisampler's face as the Mac builds it: every zone on a map of keys across
/// and velocity up — click one to edit it — a set of recordings chosen or dropped on it, the chosen
/// zone's notes, velocities and loop, dragged, and the instrument's controls.
extension RackFaces {
  static let atlasKnobs = ["tune", "attack", "release", "velocity", "level"]

  @MainActor
  static func keyAtlas(
    _ module: PatchModule, _ def: ModuleDef, x: Float, width: Float, top: Float, rack: RackSession, page: Int,
    touch: Bool = false
  ) -> Built {
    let recordings = rack.recordings[module.id] ?? []
    let busy = rack.loading.contains(module.id)
    let zones = MultisampleZone.unpack(module.data["zones"] ?? [])
    let at = min(max(0, page), max(0, zones.count - 1))
    let screen = Rect(x, top, width, 104)
    var buttons: [RackStage.Button] = []
    if zones.isEmpty {
      buttons.append(
        RackStage.Button(
          frame: screen,
          label: busy
            ? "Mapping recordings…" : touch ? "Tap to choose an instrument set" : "Drop an instrument set",
          press: busy ? nil : .choose, isOn: false, tint: Theme.nine,
          style: .prompt(detail: "names such as Piano_C3_pp.wav map themselves")))
    }
    // The map: keys across, velocity up.
    let map = screen.inset(6, 6, 6, 6)
    for (index, zone) in zones.enumerated() {
      let span = Float(zone.high - zone.low + 1)
      let root = max(0, min(1, Float(zone.root - zone.low) / max(1, span)))
      buttons.append(
        RackStage.Button(
          frame: Rect(
            map.x + map.width * Float(zone.low) / 128, map.y + map.height * Float(1 - zone.velocityHigh),
            max(2, map.width * span / 128),
            max(4, map.height * Float(max(0.04, zone.velocityHigh - zone.velocityLow)))),
          label: index < recordings.count ? recordings[index].name : "Zone \(index + 1)", press: .page(index),
          isOn: index == at, tint: Theme.nine, style: .zone(root: root, note: Multisample.noteName(zone.root))
        ))
    }

    let row = screen.maxY + 6
    buttons.append(
      RackStage.Button(
        frame: Rect(x, row + 3, 76, 14),
        label: busy ? "Loading…" : recordings.isEmpty ? "Load files" : "Replace set",
        press: busy ? nil : .choose,
        isOn: false, tint: Theme.nine, style: .option))
    var data: [RackStage.Cell] = []
    var knobsTop = row + 20 + 6
    if !zones.isEmpty {
      let count = zones.count
      for (label, to) in [("‹", (at - 1 + count) % count), ("›", (at + 1) % count)] {
        buttons.append(
          RackStage.Button(
            frame: Rect(label == "‹" ? x + 82 : x + 108, row + 3, 22, 14), label: label, press: .page(to),
            isOn: false, tint: Theme.nine, style: .option))
      }
      let zone = zones[at]
      // A press that writes the zones with the chosen one changed.
      @Sendable func edit(_ change: (inout MultisampleZone) -> Void) -> RackStage.Press {
        var next = zones
        change(&next[at])
        return .data(slot: "zones", values: MultisampleZone.pack(next), name: "Edit Zone")
      }
      func field(
        _ caption: String, _ frame: Rect, _ value: Int, _ range: ClosedRange<Int>, step: Float,
        text: @escaping @Sendable (Int) -> String, writes: @escaping @Sendable (Int) -> RackStage.Press
      ) -> RackStage.Cell {
        RackStage.Cell(
          frame: frame, value: value, range: range, slot: "zones", index: 0, padTo: 0, pad: 0,
          name: "Edit Zone",
          step: step, caption: caption, writes: writes, text: text, field: true)
      }
      let note: @Sendable (Int) -> String = { Multisample.noteName($0) }
      let hundredths: @Sendable (Int) -> String = { RackDisplay.fixed(Double($0) / 100, 2) }
      let percent: @Sendable (Int) -> String = { "\($0)%" }
      // The notes and the velocities, in a row: the Mac's drag of a quarter a point is four points
      // a note; a hundredth of velocity is two.
      let editor = row + 20 + 6
      let across = width / 5
      let slot = { (index: Int) in Rect(x + Float(index) * across + 30, editor, across - 34, 22) }
      data += [
        field("ROOT", slot(0), zone.root, 0...127, step: 4, text: note) { value in edit { $0.root = value } },
        field("LOW", slot(1), zone.low, 0...127, step: 4, text: note) { value in
          edit { $0.low = min(value, $0.high) }
        },
        field("HIGH", slot(2), zone.high, 0...127, step: 4, text: note) { value in
          edit { $0.high = max(value, $0.low) }
        },
        field("VEL", slot(3), Int((zone.velocityLow * 100).rounded()), 0...100, step: 2, text: hundredths) {
          value in edit { $0.velocityLow = min(Double(value) / 100, $0.velocityHigh) }
        },
        field("TO", slot(4), Int((zone.velocityHigh * 100).rounded()), 0...100, step: 2, text: hundredths) {
          value in edit { $0.velocityHigh = max(Double(value) / 100, $0.velocityLow) }
        },
      ]
      // The loop: whether the zone sustains on one, and where it runs, a percent at two points.
      let loopRow = editor + 22 + 4
      buttons.append(
        RackStage.Button(
          frame: Rect(x, loopRow + 4, 84, 14), label: zone.loop ? "Sustain loop" : "No loop",
          press: edit { $0.loop.toggle() }, isOn: zone.loop, tint: Theme.three, style: .option))
      data += [
        field(
          "LOOP", Rect(x + 124, loopRow, 44, 22), Int((zone.loopStart * 100).rounded()), 0...99, step: 2,
          text: percent
        ) { value in edit { $0.loopStart = min(Double(value) / 100, $0.loopEnd - 0.01) } },
        field(
          "TO", Rect(x + 196, loopRow, 44, 22), Int((zone.loopEnd * 100).rounded()), 1...100, step: 2,
          text: percent
        ) { value in edit { $0.loopEnd = max(Double(value) / 100, $0.loopStart + 0.01) } },
      ]
      knobsTop = loopRow + 22 + 6
    }
    var cells = Cells(def: def, x: x, top: knobsTop, columns: atlasKnobs.count)
    for id in atlasKnobs { cells.add(id, tint: id == "level" ? Theme.nine : nil) }
    return Built(
      words: busy ? "decoding" : recordings.isEmpty ? "empty" : "\(recordings.count) zones", cells: cells,
      mark: "MS—128", name: "Key Atlas", light: !recordings.isEmpty, screen: screen, buttons: buttons,
      dataCells: data)
  }
}

extension RackInterface {
  /// A zone on the map: violet, or teal when it is the one being edited, with a line where its
  /// root is and the root's name where there is room.
  func drawZone(_ button: RackStage.Button, root: Float, note: String, on canvas: Canvas) {
    let r = button.frame
    let chosen = button.isOn
    canvas.fill = chosen ? Theme.nine.faded(0.35) : Theme.violet.faded(0.18)
    canvas.fillRoundedRect(r.x, r.y, r.width, r.height, radius: 3)
    canvas.stroke = chosen ? Theme.nine : Theme.violet.faded(0.5)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(r.x, r.y, r.width, r.height, radius: 3)
    canvas.fill = chosen ? Theme.nine : Theme.three
    canvas.fillRect(r.x + r.width * root, r.y, 1.5, r.height)
    guard r.width > 22 else { return }
    canvas.align = .left
    canvas.font = Theme.mono(7)
    canvas.fill = Theme.ink.faded(0.85)
    canvas.fillText(note, r.x + 3, r.y + 9)
  }

  /// The atlas's screen: the octaves across it; what the chosen zone's recording is beside the
  /// buttons that step through them; and that recording's shape by its loop, with the loop over it.
  func drawAtlasScreen(_ r: Rect, face: RackStage.Face, on canvas: Canvas) {
    let module = face.module.id
    drawRecordingScreen(r, on: canvas)
    let zones = MultisampleZone.unpack(face.module.data["zones"] ?? [])
    let recordings = rack.recordings[module] ?? []
    let row = r.maxY + 6
    guard !zones.isEmpty else {
      if let failure = rack.loadFailure, failure.module == module {
        canvas.align = .left
        canvas.fill = Theme.eight
        canvas.fillText(
          Draw.fit(failure.reason, width: r.width - 90, size: 7.5, weight: 400, on: canvas), r.x + 84,
          row + 14)
      }
      return
    }
    let map = r.inset(6, 6, 6, 6)
    canvas.fill = Theme.ink.faded(0.06)
    for octave in 0..<11 {
      canvas.fillRect(map.x + map.width * Float(octave * 12) / 128, map.y, 1, map.height)
    }

    let at = min(max(0, pages[module] ?? 0), zones.count - 1)
    let recording = at < recordings.count ? recordings[at] : nil
    canvas.align = .left
    let name = Draw.fit(recording?.name ?? "Zone \(at + 1)", width: 180, size: 9, weight: 600, on: canvas)
    canvas.fill = Theme.ink
    canvas.fillText(name, r.x + 138, row + 14)
    let detail =
      recording.map { "\(RackDisplay.fixed($0.seconds, 2))s · \(Int(rack.host.sampleRate / 1000))kHz" }
      ?? "session audio unavailable"
    let after = r.x + 138 + canvas.measure(name) + 8
    canvas.font = Theme.mono(7.5)
    canvas.fill = recording == nil ? Theme.eight : Theme.dim
    canvas.fillText(detail, after, row + 14)

    // The recording by its loop fields, with the loop shaded over it while it sustains on one.
    guard let recording, let last = face.cells.last else { return }
    let zone = zones[at]
    let wave = Rect(last.frame.maxX + 12, last.frame.y, r.maxX - last.frame.maxX - 12, 24)
    guard wave.width > 20 else { return }
    drawWave(wave, peaks: recording.peaks, on: canvas)
    if zone.loop {
      let loop = Rect(
        wave.x + wave.width * Float(zone.loopStart), wave.y,
        wave.width * Float(zone.loopEnd - zone.loopStart),
        wave.height)
      canvas.fill = Theme.three.faded(0.18)
      canvas.fillRect(loop.x, loop.y, loop.width, loop.height)
      canvas.stroke = Theme.three.faded(0.6)
      canvas.lineWidth = 1
      canvas.strokeRoundedRect(loop.x, loop.y, loop.width, loop.height, radius: 0.5)
    }
  }
}
