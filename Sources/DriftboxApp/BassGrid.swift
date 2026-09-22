#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxSeq
  import SwiftUI

  /// A 303 line: for each step, whether it sounds, its pitch across two octaves, accent and slide.
  /// Clicking a cell in the pitch rows sets the note there; clicking the note that is already set
  /// pauses it; the two rows underneath toggle accent and slide.
  ///
  /// Drawn as one canvas rather than four hundred views: the playhead moves eight times a second,
  /// and re-diffing that many cells each time was a quarter of a core.
  struct BassGrid: View {
    let player: Player
    let pattern: DriftboxSeq.Pattern
    let voiceId: String
    let playhead: Int

    static let notes = Array((0...24).reversed())
    static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    static let labelWidth = 24.0
    static let cellWidth = 22.0
    static let columnStride = 24.0
    static let noteHeight = 8.0
    static let noteStride = 9.0
    static let flagHeight = 12.0
    static let flagStride = 13.0
    static var notesHeight: Double { Double(notes.count) * noteStride }
    static var height: Double { notesHeight + flagStride * 2 - 1 }

    var body: some View {
      VStack(alignment: .leading, spacing: 2) {
        BassMenu(player: player, pattern: pattern, voiceId: voiceId)
        HStack(alignment: .top, spacing: 2) {
          // The labels never change, so they are views; the cells are one drawing.
          VStack(alignment: .trailing, spacing: 0) {
            ForEach(Self.notes, id: \.self) { note in
              Text(note % 12 == 0 ? "C\(note / 12 + 1)" : Self.names[note % 12])
                .font(.system(size: 9)).frame(height: Self.noteStride)
            }
            Text("acc").font(.system(size: 9)).frame(height: Self.flagStride)
            Text("sld").font(.system(size: 9)).frame(height: Self.flagStride)
          }
          .frame(width: Self.labelWidth, alignment: .trailing)
          Canvas(rendersAsynchronously: false) { context, _ in
            draw(in: &context)
          }
          .frame(width: Double(pattern.length) * Self.columnStride - 2, height: Self.height)
          .gesture(SpatialTapGesture().onEnded { tap in click(at: tap.location) })
        }
      }
    }

    private static func x(ofStep index: Int) -> Double { Double(index) * columnStride }

    /// Every cell of one colour is a single path: five fills rather than four hundred.
    private func draw(in context: inout GraphicsContext) {
      var paths: [Color: Path] = [:]
      func add(_ rect: CGRect, _ color: Color) { paths[color, default: Path()].addRect(rect) }
      for index in 0..<pattern.length {
        let step = pattern.bassStep(voiceId, at: index)
        let x = Self.x(ofStep: index)
        for (row, note) in Self.notes.enumerated() {
          let here = Int(step.note ?? -1) == note
          add(
            CGRect(x: x, y: Double(row) * Self.noteStride, width: Self.cellWidth, height: Self.noteHeight),
            cellColor(step: step, here: here, playing: index == playhead))
        }
        add(
          CGRect(x: x, y: Self.notesHeight, width: Self.cellWidth, height: Self.flagHeight),
          step.accent ? Color.red.opacity(0.8) : Color.secondary.opacity(0.15))
        add(
          CGRect(
            x: x, y: Self.notesHeight + Self.flagStride, width: Self.cellWidth, height: Self.flagHeight),
          step.slide ? Color.blue.opacity(0.8) : Color.secondary.opacity(0.15))
      }
      for (color, path) in paths { context.fill(path, with: .color(color)) }
    }

    private func click(at point: CGPoint) {
      let column = point.x / Self.columnStride
      guard column >= 0, Int(column) < pattern.length,
        column - column.rounded(.down) <= Self.cellWidth / Self.columnStride
      else { return }
      let index = Int(column)
      if point.y < Self.notesHeight {
        let row = Int(point.y / Self.noteStride)
        guard row < Self.notes.count else { return }
        setNote(Self.notes[row], at: index)
      } else if point.y < Self.notesHeight + Self.flagStride {
        edit(index, "Set Accent") { $0.accent.toggle() }
      } else {
        edit(index, "Set Slide") { $0 = $0.settingSlide(!$0.slide) }
      }
    }

    func cellColor(step: BassStep, here: Bool, playing: Bool) -> Color {
      if here { return step.sounds ? (playing ? .orange : .orange.opacity(0.7)) : .orange.opacity(0.25) }
      return playing ? Color.secondary.opacity(0.25) : Color.secondary.opacity(0.08)
    }

    func setNote(_ note: Int, at index: Int) {
      edit(index, "Set Note") { step in
        if Int(step.note ?? -1) == note, step.sounds {
          step = step.settingGate(false)
        } else {
          step.note = Double(note)
          step = step.settingGate(true)
        }
      }
    }

    func edit(_ index: Int, _ name: String, _ change: @escaping (inout BassStep) -> Void) {
      player.edit(name) { song in
        guard let at = song.patterns.firstIndex(where: { $0.id == pattern.id }) else { return }
        var step = song.patterns[at].bassStep(voiceId, at: index)
        change(&step)
        song.patterns[at] = song.patterns[at].settingBassStep(voiceId, at: index, to: step)
      }
    }
  }
#endif
