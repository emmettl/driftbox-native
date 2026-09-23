#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxRack
  import SwiftUI

  // The faces that edit what a module plays rather than how: the Tracker's lanes, the Arranger's
  // song, the Scale Player's map and the Note Echo's pulses. All four write the module's data, which
  // reaches the sound on the next block while it plays; a drag is one step of undo however far it
  // goes.

  extension FaceContext {
    /// One of the module's data slots, as the patch holds it.
    func data(_ slot: String) -> [Double] { module.data[slot] ?? [] }

    /// Write a data slot, as part of whatever gesture is under way.
    func setData(_ slot: String, _ values: [Double], _ name: String) {
      model.setData(module.id, slot, to: values, name: name)
    }

    func endGesture() { model.endTurn() }
  }

  /// A number in a cell that a drag changes and a click acts on: the gesture the reference's
  /// Tracker and Arranger cells share. Four points of travel is one step.
  struct DragCell<Label: View>: View {
    let value: Int
    let range: ClosedRange<Int>
    let change: (Int) -> Void
    let click: () -> Void
    let end: () -> Void
    @ViewBuilder var label: () -> Label

    static var pixels: Double { 4 }

    @State private var from: Int?
    @State private var moved = false
    @State private var hovering = false

    var body: some View {
      label()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay {
          RoundedRectangle(cornerRadius: 3).strokeBorder(
            Theme.nine.opacity(hovering || from != nil ? 0.9 : 0))
        }
        .onHover { inside in
          hovering = inside
          if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { gesture in
              if from == nil { from = value }
              let travel = -gesture.translation.height
              if abs(travel) >= Self.pixels { moved = true }
              guard moved, let from else { return }
              let next = max(
                range.lowerBound, min(range.upperBound, from + Int(RackDisplay.jsRound(travel / Self.pixels)))
              )
              if next != value { change(next) }
            }
            .onEnded { _ in
              if !moved { click() }
              from = nil
              moved = false
              end()
            })
    }
  }

  /// Four lanes of up to sixty-four steps, a bar at a time: click a step to set or clear it, drag
  /// it for its value. A lane's tag is its mode — Semitones, Units, or a Curve that goes negative —
  /// and a click moves it on.
  struct TrackerFace: View {
    let face: FaceContext
    static let lanes = 4
    static let page = 16
    /// What a click writes into an empty cell: a fifth above the root, or slice 7 of 16.
    static let fresh = 7.0

    @State private var page = 0

    var body: some View {
      let length = Int(face.value("length").rounded())
      let bank = Int(face.value("pattern").rounded())
      let pages = max(1, (length + Self.page - 1) / Self.page)
      let at = min(page, pages - 1)
      let steps = (at * Self.page..<min(length, (at + 1) * Self.page)).map { $0 }
      PanelTitle(
        name: "Tracker",
        words: "P\(bank + 1) · \(length) steps" + (pages > 1 ? " · bar \(at + 1)/\(pages)" : ""))
      HStack(alignment: .top, spacing: 0) {
        face.control("length")
        face.control("pattern")
        ForEach(1...Self.lanes, id: \.self) { lane in face.control("mute\(lane)") }
      }
      VStack(alignment: .leading, spacing: 4) {
        if pages > 1 {
          HStack(spacing: 3) {
            ForEach(0..<pages, id: \.self) { index in
              Button("\(index + 1)") { page = index }
                .buttonStyle(OptionStyle(on: index == at, tint: Theme.nine))
                .accessibilityLabel("Bar \(index + 1)")
            }
          }
        }
        ForEach(0..<Self.lanes, id: \.self) { lane in
          laneRow(lane, steps: steps, base: bank * length, length: length)
        }
      }
      .padding(.horizontal, 10).padding(.bottom, 10)
      .frame(maxHeight: .infinity, alignment: .top)
    }

    private func laneRow(_ lane: Int, steps: [Int], base: Int, length: Int) -> some View {
      let values = face.data("lane\(lane + 1)")
      let mode = Int(face.value("unit\(lane + 1)").rounded())
      let curve = mode == 2
      let muted = Int(face.value("mute\(lane + 1)").rounded()) == 1
      return HStack(spacing: 2) {
        Button {
          face.set("unit\(lane + 1)", Double((mode + 1) % 3))
        } label: {
          Text("\(["S", "U", "C"][max(0, min(2, mode))])\(lane + 1)")
            .font(Theme.mono(9)).foregroundStyle(Theme.dim)
            .frame(width: 20)
        }
        .buttonStyle(.plain)
        .help("Lane \(lane + 1) plays semitones, units or a curve: click to change")
        ForEach(steps, id: \.self) { step in
          let held = base + step < values.count ? Int(values[base + step].rounded()) : 0
          DragCell(
            value: held, range: (curve ? -48 : 0)...48,
            change: { write(lane, step: step, base: base, length: length, $0) },
            click: { write(lane, step: step, base: base, length: length, held != 0 ? 0 : Int(Self.fresh)) },
            end: face.endGesture
          ) {
            Text(held != 0 ? "\(held)" : "")
              .font(Theme.mono(9))
              .foregroundStyle(held != 0 ? Theme.ground : Theme.dim)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(
                RoundedRectangle(cornerRadius: 3).fill(held != 0 ? Theme.three : Color.black.opacity(0.35))
              )
              .overlay(
                RoundedRectangle(cornerRadius: 3).strokeBorder(
                  held != 0 ? Theme.three : step % 4 == 0 ? Color.white.opacity(0.18) : Theme.edge))
          }
          .accessibilityLabel("Lane \(lane + 1) step \(step + 1)")
          .accessibilityValue(held != 0 || curve ? "\(held)" : "rest")
        }
      }
      .frame(maxHeight: 46)
      .opacity(muted ? 0.35 : 1)
    }

    /// One step of the selected pattern, the lane padded out to the end of that pattern so a
    /// step written into an empty bank slot lands rather than being dropped.
    private func write(_ lane: Int, step: Int, base: Int, length: Int, _ value: Int) {
      var values = face.data("lane\(lane + 1)")
      while values.count < base + length { values.append(0) }
      values[base + step] = Double(value)
      face.setData("lane\(lane + 1)", values, "Edit Step")
    }
  }

  /// Sixteen sections of a song in two columns: which pattern each plays and for how many bars.
  /// Drag either number; click a pattern to step it on.
  struct ArrangerFace: View {
    let face: FaceContext
    static let sections = 16
    /// The bars a fresh section lasts: a phrase.
    static let bars = 4

    var body: some View {
      let length = Int(face.value("length").rounded())
      let patterns = face.data("patterns")
      let repeats = face.data("repeats")
      let total = (0..<length).reduce(0) { $0 + Self.count(repeats, $1) }
      PanelTitle(name: "Arranger", words: "\(total) bars")
      face.control("length")
      HStack(alignment: .top, spacing: 10) {
        ForEach(0..<2, id: \.self) { column in
          VStack(spacing: 2) {
            HStack(spacing: 3) {
              Text("").frame(width: 14)
              Text("PTN").frame(maxWidth: .infinity)
              Text("BARS").frame(maxWidth: .infinity)
            }
            .font(Theme.mono(8)).tracking(0.6).foregroundStyle(Theme.dim)
            ForEach(0..<Self.sections / 2, id: \.self) { row in
              let at = column * (Self.sections / 2) + row
              let pattern = at < patterns.count ? Int(RackDisplay.jsRound(patterns[at])) : 0
              let count = Self.count(repeats, at)
              HStack(spacing: 3) {
                Text("\(at + 1)").font(Theme.mono(9)).foregroundStyle(Theme.dim).frame(
                  width: 14, alignment: .trailing)
                cell("patterns", at, pattern, 0...7, label: "pattern") {
                  write("patterns", at, pattern >= 7 ? 0 : pattern + 1)
                }
                cell("repeats", at, count, 1...64, label: "bars") {}
              }
              .opacity(at < length ? 1 : 0.3)
            }
          }
        }
      }
      .padding(.horizontal, 10).padding(.bottom, 10)
      .frame(maxHeight: .infinity)
    }

    static func count(_ repeats: [Double], _ at: Int) -> Int {
      max(1, Int(RackDisplay.jsRound(at < repeats.count ? repeats[at] : Double(bars))))
    }

    private func cell(
      _ slot: String, _ at: Int, _ held: Int, _ range: ClosedRange<Int>, label: String,
      click: @escaping () -> Void
    ) -> some View {
      DragCell(value: held, range: range, change: { write(slot, at, $0) }, click: click, end: face.endGesture)
      {
        Text("\(held)")
          .font(Theme.mono(10)).foregroundStyle(Theme.ink)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.35)))
          .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.edge))
      }
      .accessibilityLabel("Section \(at + 1) \(label)")
      .accessibilityValue("\(held)")
    }

    /// Padded to all sixteen, with the default bars for a section never written, so a section
    /// written past the end lands on the row that was clicked.
    private func write(_ slot: String, _ at: Int, _ value: Int) {
      var values = face.data(slot)
      while values.count < Self.sections { values.append(slot == "repeats" ? Double(Self.bars) : 0) }
      values[at] = Double(value)
      face.setData(slot, values, "Edit Song")
    }
  }

  /// The twelve notes of the scale, from its key: lit when in it. A click takes the map to Custom
  /// and toggles the note — never the last one out.
  struct ScalePlayerFace: View {
    let face: FaceContext
    static let notes = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let black: Set<Int> = [1, 3, 6, 8, 10]
    static let custom = 13

    var body: some View {
      let key = max(0, min(11, Int(face.value("key").rounded())))
      let scale = max(0, min(13, Int(face.value("scale").rounded())))
      let filtering = Int(face.value("filter").rounded()) == 1
      let mask = Self.mask(scale, face.data("customScale"))
      let count = mask.filter { $0 >= 0.5 }.count
      let names = ModuleFace.byType["scale-player"]?.labels["scale"]
      let scaleName = names.flatMap { scale < $0.count ? $0[scale] : nil } ?? "Scale \(scale + 1)"
      PanelTitle(name: "Scale Map", mark: "SP—13", markTint: Theme.violet) {
        Text("\(Self.notes[key]) \(scaleName) · \(filtering ? "filter" : "correct")")
          .font(Theme.mono(9)).foregroundStyle(Theme.dim.opacity(0.8)).lineLimit(1)
      }
      ZStack(alignment: .bottom) {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(
            RadialGradient(
              colors: [
                Color(red: 77 / 255, green: 54 / 255, blue: 135 / 255).opacity(0.32),
                Color(red: 7 / 255, green: 5 / 255, blue: 13 / 255).opacity(0.97),
              ],
              center: .top, startRadius: 0, endRadius: 260)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.violet.opacity(0.23)))
        HStack(alignment: .top, spacing: 3) {
          ForEach(0..<12, id: \.self) { relative in
            pianoKey(relative, key: key, mask: mask, count: count, scale: scale)
          }
        }
        .padding(.horizontal, 10).padding(.top, 9)
        .frame(maxHeight: .infinity, alignment: .top)
        HStack {
          Text("\(count) notes")
          Spacer()
          Text(scale == Self.custom ? "CUSTOM MAP" : "CLICK A KEY TO CUSTOMISE").foregroundStyle(Theme.nine)
          Spacer()
          Text(filtering ? "WRONG NOTES SILENT" : "NEAREST NOTE · TIES DOWN")
        }
        .font(Theme.mono(7)).tracking(0.3).foregroundStyle(Theme.dim)
        .padding(.horizontal, 10).padding(.bottom, 5)
      }
      .frame(height: 92)
      HStack(spacing: 0) {
        face.control("key", tint: Theme.three)
        face.control("scale", tint: Theme.nine)
        face.control("filter")
      }
      .frame(maxWidth: .infinity)
      .overlay(alignment: .top) { Rectangle().fill(Theme.violet.opacity(0.12)).frame(height: 1) }
    }

    private func pianoKey(_ relative: Int, key: Int, mask: [Double], count: Int, scale: Int) -> some View {
      let actual = (key + relative) % 12
      let black = Self.black.contains(actual)
      let on = mask[relative] >= 0.5
      let fill: AnyShapeStyle =
        on
        ? AnyShapeStyle(
          LinearGradient(
            colors: black
              ? [Color(red: 1, green: 225 / 255, blue: 160 / 255), Theme.three]
              : [Color(red: 222 / 255, green: 213 / 255, blue: 1), Theme.nine],
            startPoint: .top, endPoint: .bottom))
        : AnyShapeStyle(
          black
            ? Color(red: 2 / 255, green: 2 / 255, blue: 5 / 255).opacity(0.82)
            : Color(red: 226 / 255, green: 224 / 255, blue: 238 / 255).opacity(0.07))
      return Button {
        guard !(on && count <= 1) else { return }
        var next = mask
        next[relative] = on ? 0 : 1
        face.setData("customScale", next, "Edit Scale")
        face.endGesture()
        if scale != Self.custom { face.set("scale", Double(Self.custom)) }
      } label: {
        ZStack {
          UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4).fill(fill)
          UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
            .strokeBorder(on ? (black ? Theme.three : Theme.violet).opacity(0.85) : Theme.ink.opacity(0.16))
          VStack {
            if relative == 0 { Text("ROOT").font(Theme.mono(6)).tracking(0.5).padding(.top, 4) }
            Spacer()
            Text(Self.notes[actual]).font(Theme.mono(8)).padding(.bottom, 5)
          }
          .foregroundStyle(
            on
              ? (black
                ? Color(red: 41 / 255, green: 21 / 255, blue: 0)
                : Color(red: 16 / 255, green: 10 / 255, blue: 32 / 255)) : Theme.ink.opacity(0.36))
        }
        .frame(height: black ? 42 : 57)
        .shadow(color: on ? (black ? Theme.three : Theme.violet).opacity(0.35) : .clear, radius: 4)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(Self.notes[actual]) \(on ? "included" : "excluded")")
      .help("Click to edit a Custom scale")
    }

    /// The reference's `scalePlayerMask`: which of the twelve notes from the key a scale has, with
    /// an empty custom map falling back to major.
    nonisolated static let presets: [[Int]] = [
      [0, 2, 4, 5, 7, 9, 11], [0, 2, 3, 5, 7, 8, 10], [0, 2, 4, 6, 7, 9, 11], [0, 2, 4, 5, 7, 9, 10],
      [0, 1, 4, 5, 7, 8, 10], [0, 2, 3, 5, 7, 9, 10], [0, 1, 3, 5, 7, 8, 10], [0, 2, 3, 5, 7, 8, 11],
      [0, 2, 3, 5, 7, 9, 11], [0, 2, 4, 7, 9], [0, 3, 5, 7, 10], [0, 1, 5, 7, 8],
      [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
    ]

    nonisolated static func mask(_ scale: Int, _ custom: [Double]) -> [Double] {
      let which = max(0, min(13, scale))
      let degrees: [Int] =
        which < presets.count
        ? presets[which]
        : custom.contains(where: { $0 >= 0.5 }) ? custom.indices.filter { custom[$0] >= 0.5 } : presets[0]
      return (0..<12).map { degrees.contains($0) ? 1 : 0 }
    }
  }

  /// The note echo: the dry note and sixteen repeats as pulses, as tall as their velocity; the
  /// ones past the repeat count asleep; a click mutes or unmutes one.
  struct NoteEchoFace: View {
    let face: FaceContext
    static let steps = 17
    nonisolated static let knobs = [
      "sync", "time", "division", "repeats", "pitch", "velocity", "gate", "dry",
    ]

    var body: some View {
      let repeats = max(1, min(16, Int(face.value("repeats").rounded())))
      let pitch = Int(face.value("pitch").rounded())
      let velocity = face.value("velocity")
      let sync = Int(face.value("sync").rounded()) == 1
      let division = max(0, min(7, Int(face.value("division").rounded())))
      let stored = face.data("steps")
      let steps = (0..<Self.steps).map { $0 < stored.count ? stored[$0] : 1 }
      let divisions = ModuleFace.byType["note-echo"]?.labels["division"]
      let interval =
        sync
        ? divisions.flatMap { division < $0.count ? $0[division] : nil } ?? "step \(division + 1)"
        : "\(Int(face.value("time").rounded()))ms"
      PanelTitle(name: "Echo Matrix", mark: "NE—16") {
        Text("\(repeats) repeats · \(interval)").font(Theme.mono(9)).foregroundStyle(Theme.dim.opacity(0.8))
      }
      ZStack(alignment: .bottom) {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(
            RadialGradient(
              colors: [
                Color(red: 99 / 255, green: 61 / 255, blue: 12 / 255).opacity(0.34),
                Color(red: 10 / 255, green: 6 / 255, blue: 2 / 255).opacity(0.95),
              ],
              center: .bottom, startRadius: 0, endRadius: 260)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.three.opacity(0.22)))
        HStack(alignment: .bottom, spacing: 2) {
          ForEach(0..<Self.steps, id: \.self) { index in
            pulse(
              index, on: steps[index] >= 0.5, active: index <= repeats, velocity: velocity, pitch: pitch,
              steps: steps)
          }
        }
        .padding(.init(top: 8, leading: 9, bottom: 23, trailing: 9))
        HStack {
          Text("VELOCITY SLOPE")
          Spacer()
          Text("\(pitch > 0 ? "+" : "")\(pitch) ST / REPEAT").foregroundStyle(Theme.three)
          Spacer()
          Text("CLICK A PULSE TO MUTE")
        }
        .font(Theme.mono(7)).tracking(0.3).foregroundStyle(Theme.dim)
        .padding(.horizontal, 9).padding(.bottom, 5)
      }
      .frame(height: 106)
      LazyVGrid(
        columns: Array(repeating: GridItem(.fixed(RackLayout.cellWidth), spacing: 0), count: 4), spacing: 0
      ) {
        ForEach(Self.knobs, id: \.self) { id in
          face.control(id, tint: id == "pitch" ? Theme.three : id == "velocity" ? Theme.nine : nil)
        }
      }
      .frame(maxWidth: .infinity)
      .overlay(alignment: .top) { Rectangle().fill(Theme.three.opacity(0.12)).frame(height: 1) }
    }

    private func pulse(_ index: Int, on: Bool, active: Bool, velocity: Double, pitch: Int, steps: [Double])
      -> some View
    {
      let amount = index == 0 ? 1 : max(0, min(1, 1 + (velocity - 1) * Double(index)))
      let lit = on && active
      return Button {
        var next = steps
        next[index] = on ? 0 : 1
        face.setData("steps", next, "Edit Echoes")
        face.endGesture()
      } label: {
        ZStack(alignment: .bottom) {
          RoundedRectangle(cornerRadius: 3)
            .fill(lit ? Theme.three.opacity(0.12) : Color.white.opacity(0.02))
          RoundedRectangle(cornerRadius: 3)
            .strokeBorder(lit ? Theme.three.opacity(0.72) : Theme.ink.opacity(0.1))
          UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
            .fill(
              lit
                ? AnyShapeStyle(
                  LinearGradient(
                    colors: [Color(red: 1, green: 223 / 255, blue: 148 / 255), Theme.three], startPoint: .top,
                    endPoint: .bottom))
                : AnyShapeStyle(Theme.dim.opacity(0.16))
            )
            .frame(height: max(3, amount * 44))
            .shadow(color: lit ? Theme.three.opacity(0.55) : .clear, radius: 4)
            .padding(.horizontal, 3).padding(.bottom, 13)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: amount)
          Text(index == 0 ? "D" : "\(index)").font(Theme.mono(7))
            .foregroundStyle(lit ? Color(red: 43 / 255, green: 23 / 255, blue: 0) : Theme.ink.opacity(0.36))
            .padding(.bottom, 2)
        }
        .frame(height: 66)
      }
      .buttonStyle(.plain)
      .disabled(!active)
      .opacity(active ? 1 : 0.22)
      .accessibilityLabel(index == 0 ? "Dry note" : "Repeat \(index), \(pitch * index) semitones")
      .accessibilityValue(on ? "on" : "muted")
    }
  }
#endif
