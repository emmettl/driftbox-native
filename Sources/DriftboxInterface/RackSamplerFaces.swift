import DriftboxCanvas
import DriftboxRack
import DriftboxRackSession

/// The faces that hold a recording, laid out as the Mac's are: the Sampler's slices over the
/// sample's shape, and an Audio Track's recording and where it starts. A file is chosen from the
/// face's button, or its screen while it is empty, or dropped anywhere on the face.
extension RackFaces {
  static let sampleBars = [1, 2, 4, 8]

  /// The Slice Lab: the sample's shape with its slices over it — click one to play from it — the
  /// length it is taken to be in bars, and the sampler's controls.
  @MainActor
  static func sampler(
    _ module: PatchModule, _ def: ModuleDef, x: Float, width: Float, top: Float, rack: RackSession,
    touch: Bool = false
  ) -> Built {
    let info = rack.samples[module.id]
    let busy = rack.loading.contains(module.id)
    let slices = max(1, min(32, Int(param(module, def, "slices", rack).rounded())))
    let selected = max(0, min(slices - 1, Int(param(module, def, "slice", rack).rounded())))
    let screen = Rect(x, top, width, 84)
    var buttons: [RackStage.Button] = []
    if info != nil {
      let row = Rect(x + 8, screen.maxY - 6 - 16, width - 16, 16)
      let sliceWidth = (row.width - 2 * Float(slices - 1)) / Float(slices)
      for index in 0..<slices {
        buttons.append(
          RackStage.Button(
            frame: Rect(row.x + Float(index) * (sliceWidth + 2), row.y, sliceWidth, row.height),
            label: slices <= 16 ? "\(index + 1)" : "", press: .set(param: "slice", value: Double(index)),
            isOn: index == selected, tint: Theme.nine, style: .slice(accent: index % 4 == 0)))
      }
    } else {
      buttons.append(
        RackStage.Button(
          frame: screen,
          label: busy ? "Reading sample…" : touch ? "Tap to choose a sample" : "Drop audio here",
          press: busy ? nil : .choose, isOn: false, tint: Theme.nine,
          style: .prompt(detail: touch ? rack.readable : "or choose \(rack.readable)")))
    }
    let rowY = screen.maxY + 6
    buttons.append(
      RackStage.Button(
        frame: Rect(x, rowY + 4, 76, 14), label: busy ? "Loading…" : info == nil ? "Load sample" : "Replace",
        press: busy ? nil : .choose, isOn: false, tint: Theme.nine, style: .option))
    if let info {
      for (index, bars) in sampleBars.enumerated() {
        buttons.append(
          RackStage.Button(
            frame: Rect(x + width - Float(sampleBars.count - index) * 25 + 3, rowY + 4, 22, 14),
            label: "\(bars)", press: .sampleBars(bars), isOn: info.bars == bars, tint: Theme.three,
            style: .option))
      }
    }
    var cells = Cells(def: def, x: x, top: rowY + 22 + 6, columns: 5)
    cells.add("slices")
    // The slice, stepped round rather than stopped at its ends: the Mac's own cell.
    let slice = cells.next
    cells.skip()
    for (label, to) in [("‹", (selected - 1 + slices) % slices), ("›", (selected + 1) % slices)] {
      buttons.append(
        RackStage.Button(
          frame: Rect(label == "‹" ? slice.midX - 23 : slice.midX + 2, slice.y + 24, 21, 16), label: label,
          press: .set(param: "slice", value: Double(to)), isOn: false, tint: Theme.nine, style: .chip))
    }
    cells.add("start", tint: Theme.three)
    cells.add("loop")
    cells.add("reverse")
    return Built(
      words: busy ? "decoding" : info == nil ? "empty" : "sample ready", cells: cells, mark: "S—32",
      name: "Slice Lab", light: info != nil, screen: screen, buttons: buttons)
  }

  /// Where `start`, in sixteenths, is as a bar and a step, both from one: the reference's
  /// `audioTrackPosition`.
  static func position(_ start: Double) -> (bar: Int, step: Int) {
    let safe = max(0, min(1023, Int(RackDisplay.jsRound(start))))
    return (safe / 16 + 1, safe % 16 + 1)
  }

  /// An audio track: one recording, placed on the timeline at a bar and step, playing from there
  /// with the transport.
  @MainActor
  static func audioTrack(
    _ module: PatchModule, _ def: ModuleDef, x: Float, width: Float, top: Float, rack: RackSession,
    touch: Bool = false
  ) -> Built {
    let track = rack.tracks[module.id]
    let busy = rack.loading.contains(module.id)
    let (bar, step) = position(param(module, def, "start", rack))
    let screen = Rect(x, top, width, 86)
    var buttons: [RackStage.Button] = []
    if track == nil {
      buttons.append(
        RackStage.Button(
          frame: screen,
          label: busy ? "Reading audio…" : touch ? "Tap to choose a recording" : "Drop audio here",
          press: busy ? nil : .choose, isOn: false, tint: Theme.nine,
          style: .prompt(detail: touch ? rack.readable : "or choose a local recording")))
    }
    let rowY = screen.maxY + 6
    let height = Float(RackLayout.cellHeight)
    buttons.append(
      RackStage.Button(
        frame: Rect(x, rowY + (height - 14) / 2, 76, 14),
        label: busy ? "Loading…" : track == nil ? "Load audio" : "Replace", press: busy ? nil : .choose,
        isOn: false, tint: Theme.nine, style: .option))
    let level = x + width - Float(RackLayout.cellWidth)
    var cells = Cells(def: def, x: level, top: rowY, columns: 1)
    cells.add("level", tint: Theme.nine)
    // The start as a bar and a step, each dragged: ten points a step, as the Mac's numbers are.
    let numberY = rowY + (height - 18) / 2
    let stepCell = Rect(level - 8 - 30, numberY, 30, 18)
    let barCell = Rect(stepCell.x - 34 - 30, numberY, 30, 18)
    let data = [
      RackStage.Cell(
        frame: barCell, value: bar, range: 1...64, slot: "", index: 0, padTo: 0, pad: 0, name: "Set Start",
        click: nil, param: ("start", Double(step - 1 - 16), 16), step: 10, caption: "BAR"),
      RackStage.Cell(
        frame: stepCell, value: step, range: 1...16, slot: "", index: 0, padTo: 0, pad: 0, name: "Set Start",
        click: nil, param: ("start", Double((bar - 1) * 16 - 1), 1), step: 10, caption: "STEP"),
    ]
    return Built(
      words: "stereo · timeline", cells: cells, mark: "AT—64", name: "Audio Track", screen: screen,
      buttons: buttons, dataCells: data)
  }
}
