import DriftboxCanvas
import DriftboxRack
import DriftboxRackSession
import DriftboxSeq

/// The Groovebox, the rack's window onto the song it carries, as the Mac builds it: four strips,
/// one a machine, each with its meter, level, pan and mute; what the song is; and its arrangement,
/// section by section, to start the song from or loop. The song is edited in the groovebox, which is
/// the editor, linked to the rack's copy so each edit plays on here in place.
extension RackFaces {
  /// Each machine: the section its meter reads, the id its params are named by, and its name.
  static let machines = [
    ("tr808", "tr808", "808"), ("tr909", "tr909", "909"), ("303.a", "303-a", "303 A"),
    ("303.b", "303-b", "303 B"),
  ]

  /// A section of the arrangement: which pattern, its first bar and how many bars it runs.
  struct Section {
    var index: Int
    var name: String
    var start: Int
    var bars: Int
  }

  static func sections(_ song: Song) -> [Section] {
    var start = 0
    return song.chain.enumerated().map { index, step in
      let bars = max(1, step.repeat)
      defer { start += bars }
      return Section(
        index: index, name: song.patterns.first { $0.id == step.pattern }?.name ?? step.pattern, start: start,
        bars: bars)
    }
  }

  static let sectionHeight: Float = 22

  @MainActor
  static func groovebox(
    _ module: PatchModule, _ def: ModuleDef, x: Float, width: Float, top: Float, bottom: Float,
    rack: RackSession
  ) -> Built {
    var buttons: [RackStage.Button] = []
    if rack.song != nil {
      buttons.append(
        RackStage.Button(
          frame: Rect(x + width - 128, top + 1, 128, 14),
          label: rack.songLinked ? "Editing in Groovebox" : "Edit in Groovebox",
          press: rack.songLinked ? nil : .editSong, isOn: rack.songLinked, tint: Theme.nine, style: .option))
    }
    // The strips: a column a machine, its level, pan and mute under its name and meter.
    let column = width / Float(machines.count)
    var cells = Cells(def: def, x: x, top: top + 22 + 27, columns: machines.count, cellWidth: column)
    for (part, name) in [("level", "Level"), ("pan", "Pan"), ("mute", "Mute")] {
      for (_, id, _) in machines {
        cells.add(
          "\(id)-\(part)", tint: part == "level" ? Theme.nine : part == "pan" ? Theme.eight : nil, name: name)
      }
    }
    // The arrangement, under them: as many sections as fit, each played from or looped.
    let area = top + 22 + 27 + Float(RackLayout.cellHeight) * 3 + 6
    let screen = Rect(x, area, width, max(0, bottom - area))
    if let song = rack.song {
      if let loop = rack.songLoop {
        buttons.append(
          RackStage.Button(
            frame: Rect(x + width - 150, area + 1, 150, 14),
            label: "Loop bars \(loop.start + 1)–\(loop.start + loop.bars) ×", press: .clearLoop, isOn: true,
            tint: Theme.three, style: .option))
      }
      for section in shown(song, in: screen) {
        let row = sectionRow(section.index, in: screen)
        let looped = rack.songLoop.map { $0.start == section.start && $0.bars == section.bars } ?? false
        buttons += [
          RackStage.Button(
            frame: Rect(row.maxX - 56, row.y + 4, 22, 14), label: "▶", press: .startSong(bar: section.start),
            isOn: false, tint: Theme.nine, style: .option),
          RackStage.Button(
            frame: Rect(row.maxX - 30, row.y + 4, 22, 14), label: "⟳",
            press: .loopSong(start: section.start, bars: section.bars), isOn: looped, tint: Theme.three,
            style: .option),
        ]
      }
    }
    return Built(words: "4 stereo sources", cells: cells, screen: screen, buttons: buttons)
  }

  /// Where section `index` sits in the arrangement `screen`: under its heading, a row each.
  static func sectionRow(_ index: Int, in screen: Rect) -> Rect {
    Rect(screen.x, screen.y + 20 + Float(index) * (sectionHeight + 2), screen.width, sectionHeight)
  }

  /// The sections that fit the arrangement's `screen`, with a line kept for saying how many more
  /// there are when not all do.
  static func shown(_ song: Song, in screen: Rect) -> [Section] {
    let all = sections(song)
    let fits = max(0, Int((screen.height - 20) / (sectionHeight + 2)))
    return all.count <= fits ? all : Array(all.prefix(max(0, fits - 1)))
  }
}

extension RackInterface {
  /// The groovebox's names and meters over its strips, what its song is, and its arrangement.
  func drawGroovebox(_ r: Rect, face: RackStage.Face, on canvas: Canvas) {
    let module = face.module.id
    let top = face.title.maxY + 6
    let column = r.width / Float(RackFaces.machines.count)
    // What the song is, or how to bring one in.
    canvas.align = .left
    canvas.font = Theme.mono(9.5)
    canvas.fill = Theme.ink
    if let song = rack.song {
      canvas.fillText(
        "\(song.patterns.count) pattern\(song.patterns.count == 1 ? "" : "s") · "
          + "\(RackDisplay.fixed(rack.tempo, 0)) BPM · \(max(1, song.bars)) bars", r.x, top + 11)
    } else {
      canvas.font = Theme.mono(9)
      canvas.fill = Theme.dim
      // Where the songs are: the patch's chip, where there is no menu bar, as on a touchscreen.
      canvas.fillText(
        groovebox == nil
          ? "No song: choose one under Rack ▸ Groovebox Songs,"
          : "No song: the patch's chip has Groovebox Songs,",
        r.x, top + 6)
      canvas.fillText("and its machines come in here.", r.x, top + 18)
    }
    // Each strip's name, and its meter: −48 dB to +3, pink where it clipped.
    for (index, machine) in RackFaces.machines.enumerated() {
      let middle = r.x + column * (Float(index) + 0.5)
      canvas.align = .center
      canvas.font = Theme.mono(11, weight: 600)
      canvas.fill = Theme.ink
      canvas.fillText(machine.2, middle, top + 22 + 11)
      let reading = rack.readings["\(module):\(machine.0)"]
      let meter = Rect(middle - 35, top + 22 + 18, 70, 5)
      canvas.fill = Colour(0x000000, alpha: 0.35)
      canvas.fillRoundedRect(meter.x, meter.y, meter.width, meter.height, radius: 2.5)
      let level = Float(RackDisplay.meterPosition(reading?.envelope ?? 0))
      if level > 0 {
        canvas.fill = (reading?.peak ?? 0) > 1 ? Theme.eight : Theme.nine
        canvas.fillRoundedRect(meter.x, meter.y, max(5, meter.width * level), meter.height, radius: 2.5)
      }
    }
    guard let song = rack.song else { return }
    canvas.align = .left
    canvas.font = Theme.mono(8, weight: 500)
    canvas.fill = Theme.dim
    canvas.fillText("ARRANGEMENT", r.x, r.y + 11)
    if song.chain.isEmpty {
      canvas.font = Theme.mono(9)
      canvas.fillText("One pattern, round and round.", r.x, r.y + 32)
      return
    }
    let shown = RackFaces.shown(song, in: r)
    for section in shown {
      let row = RackFaces.sectionRow(section.index, in: r)
      let playing = rack.songBar.map { $0 >= section.start && $0 < section.start + section.bars } ?? false
      canvas.fill = playing ? Theme.nine.faded(0.14) : Theme.white(0.03)
      canvas.fillRoundedRect(row.x, row.y, row.width, row.height, radius: 5)
      if playing {
        canvas.stroke = Theme.nine.faded(0.5)
        canvas.lineWidth = 1
        canvas.strokeRoundedRect(row.x, row.y, row.width, row.height, radius: 5)
      }
      let baseline = row.midY + 3.5
      canvas.align = .center
      canvas.font = Theme.mono(9)
      canvas.fill = Theme.dim
      canvas.fillText("\(section.index + 1)", row.x + 17, baseline)
      canvas.align = .right
      let bars =
        section.bars == 1
        ? "bar \(section.start + 1)" : "bars \(section.start + 1)–\(section.start + section.bars)"
      canvas.fillText(bars, row.maxX - 64, baseline)
      let room = row.maxX - 64 - canvas.measure(bars) - 12 - (row.x + 34)
      canvas.align = .left
      canvas.fill = Theme.ink
      canvas.fillText(
        Draw.fit(section.name, width: room, size: 10, weight: 600, on: canvas), row.x + 34, baseline)
    }
    let all = RackFaces.sections(song).count
    if shown.count < all {
      canvas.align = .left
      canvas.font = Theme.mono(9)
      canvas.fill = Theme.dim
      let row = RackFaces.sectionRow(shown.count, in: r)
      canvas.fillText("and \(all - shown.count) more sections", row.x + 34, row.midY + 3.5)
    }
  }
}
