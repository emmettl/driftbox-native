#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxSeq
  import DriftboxSession
  import SwiftUI

  /// A 303 line: for each step, whether it sounds, its pitch across two octaves, accent and slide.
  /// Clicking a cell in the pitch rows sets the note there; clicking the note that is already set
  /// pauses it; the two rows underneath toggle accent and slide. Its columns are the drum
  /// grid's, so a note sits under the kick it plays against.
  ///
  /// Drawn as one canvas rather than four hundred views: the playhead moves eight times a second,
  /// and re-diffing that many cells each time was a quarter of a core.
  struct BassGrid: View {
    let player: Session
    let pattern: DriftboxSeq.Pattern
    let voiceId: String
    var metrics = GridMetrics(steps: 16, width: 0)
    let playhead: Int
    var selected = false
    /// Where step entry writes next, when it writes into this line.
    var entry: Int?

    static let notes = Array((0...24).reversed())
    static let noteHeight = 7.0
    static let noteStride = 8.5
    static let flagHeight = 13.0
    static let flagStride = 16.0
    static var notesHeight: Double { Double(notes.count) * noteStride }
    static var height: Double { notesHeight + 4 + flagStride * 2 }
    /// Where the flag rows start, below a small gap under the notes.
    static var flagsTop: Double { notesHeight + 4 }

    /// The black keys, counting up from C, for shading their rows as a piano roll does.
    static let blackKeys: Set<Int> = [1, 3, 6, 8, 10]

    var name: String { voiceId == "303.a" ? "303 A" : "303 B" }

    var body: some View {
      HStack(alignment: .top, spacing: 0) {
        header.frame(width: GridMetrics.labelWidth, alignment: .topLeading)
        Canvas(rendersAsynchronously: false) { context, _ in
          draw(in: &context)
        }
        .frame(width: metrics.stride * Double(pattern.length) - GridMetrics.gap, height: Self.height)
        .gesture(SpatialTapGesture().onEnded { tap in click(at: tap.location) })
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 4)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(selected ? 0.06 : 0)))
    }

    private var header: some View {
      let right = GridMetrics.labelWidth - 10
      return ZStack(alignment: .topLeading) {
        HStack(alignment: .top, spacing: 2) {
          Button {
            player.selectedVoice = selected ? nil : voiceId
          } label: {
            VStack(alignment: .leading, spacing: 1) {
              Text("TB-303").font(Theme.mono(8.5, .semibold)).tracking(1).foregroundStyle(Theme.three)
              Text(name).font(Theme.mono(12, .semibold))
                .foregroundStyle(selected ? Theme.ink : Theme.ink.opacity(0.8))
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("Show \(name)'s knobs")
          BassMenu(player: player, pattern: pattern, voiceId: voiceId)
        }
        // The octave marks level with their rows, and the flag rows' names level with theirs.
        ForEach([24, 12, 0], id: \.self) { note in
          Text("C\(note / 12 + 1)").font(Theme.mono(8)).foregroundStyle(Theme.dim.opacity(0.7))
            .frame(width: right, alignment: .trailing)
            .offset(y: Double(24 - note) * Self.noteStride - 2)
        }
        Text("ACCENT").font(Theme.mono(8, .medium)).foregroundStyle(Theme.dim)
          .frame(width: right, alignment: .trailing).offset(y: Self.flagsTop + 1)
        Text("SLIDE").font(Theme.mono(8, .medium)).foregroundStyle(Theme.dim)
          .frame(width: right, alignment: .trailing).offset(y: Self.flagsTop + Self.flagStride + 1)
      }
      .frame(height: Self.height, alignment: .topLeading)
    }

    private func x(ofStep index: Int) -> Double { Double(index) * metrics.stride }

    /// Every cell of one colour is a single path: a handful of fills rather than four hundred.
    private func draw(in context: inout GraphicsContext) {
      let cell = metrics.cell
      let width = metrics.stride * Double(pattern.length) - GridMetrics.gap
      var paths: [Color: Path] = [:]
      func add(_ rect: CGRect, _ color: Color, radius: Double = 2) {
        paths[color, default: Path()].addRoundedRect(
          in: rect, cornerSize: CGSize(width: radius, height: radius))
      }
      // The keyboard behind the cells: the black keys' rows darker, as on a piano roll.
      for (row, note) in Self.notes.enumerated() where Self.blackKeys.contains(note % 12) {
        context.fill(
          Path(CGRect(x: 0, y: Double(row) * Self.noteStride - 1, width: width, height: Self.noteStride)),
          with: .color(Color.black.opacity(0.28)))
      }
      if playhead >= 0, playhead < pattern.length {
        // Lighter than the drums' playhead: a column this tall at full strength would be the
        // brightest thing in the window, and it is only saying where the drums already say.
        let column = CGRect(x: x(ofStep: playhead) - 1, y: -1, width: cell + 2, height: Self.notesHeight)
        context.fill(Path(roundedRect: column, cornerRadius: 3), with: .color(Theme.live.opacity(0.09)))
        context.stroke(
          Path(roundedRect: column, cornerRadius: 3), with: .color(Theme.live.opacity(0.3)), lineWidth: 1)
      }
      if let entry, entry < pattern.length {
        // Step entry's cursor: the column the next note typed goes into, notes and flags both.
        // Inside the canvas, which clips anything past its edges.
        let column = CGRect(x: x(ofStep: entry), y: 0, width: cell, height: Self.height)
          .insetBy(dx: 0.75, dy: 0.75)
        context.fill(Path(roundedRect: column, cornerRadius: 3), with: .color(Theme.three.opacity(0.14)))
        context.stroke(
          Path(roundedRect: column, cornerRadius: 3), with: .color(Theme.three.opacity(0.9)), lineWidth: 1.5)
      }
      var lit: [(CGRect, Bool)] = []
      for index in 0..<pattern.length {
        let step = pattern.bassStep(voiceId, at: index)
        let x = x(ofStep: index)
        let onBeat = index % 4 == 0
        for (row, note) in Self.notes.enumerated() {
          let rect = CGRect(x: x, y: Double(row) * Self.noteStride, width: cell, height: Self.noteHeight)
          if Int(step.note ?? -1) == note {
            lit.append((rect, step.sounds))
          } else {
            add(rect, Color.white.opacity(onBeat ? 0.07 : 0.035))
          }
        }
        add(
          CGRect(x: x, y: Self.flagsTop, width: cell, height: Self.flagHeight),
          step.accent ? Theme.three : Color.white.opacity(onBeat ? 0.07 : 0.035), radius: 3)
        add(
          CGRect(x: x, y: Self.flagsTop + Self.flagStride, width: cell, height: Self.flagHeight),
          step.slide ? Theme.violet : Color.white.opacity(onBeat ? 0.07 : 0.035), radius: 3)
      }
      for (color, path) in paths { context.fill(path, with: .color(color)) }
      // The notes last, glowing, over everything; a paused one is only an outline of where it
      // would be.
      context.drawLayer { layer in
        layer.addFilter(.shadow(color: Theme.three.opacity(0.7), radius: 5))
        for (rect, sounds) in lit where sounds {
          layer.fill(Path(roundedRect: rect, cornerRadius: 2), with: Theme.bassShading(in: rect))
        }
      }
      for (rect, sounds) in lit where !sounds {
        context.stroke(
          Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2),
          with: .color(Theme.three.opacity(0.55)), lineWidth: 1)
      }
    }

    /// What a click at `point` lands on.
    enum Hit: Equatable {
      case note(Int, step: Int)
      case accent(step: Int)
      case slide(step: Int)
    }

    func hit(at point: CGPoint) -> Hit? {
      let column = point.x / metrics.stride
      guard column >= 0, Int(column) < pattern.length,
        column - column.rounded(.down) <= metrics.cell / metrics.stride
      else { return nil }
      let index = Int(column)
      if point.y < Self.notesHeight {
        let row = Int(max(0, point.y) / Self.noteStride)
        guard row < Self.notes.count else { return nil }
        return .note(Self.notes[row], step: index)
      }
      if point.y >= Self.flagsTop, point.y < Self.flagsTop + Self.flagStride { return .accent(step: index) }
      if point.y >= Self.flagsTop + Self.flagStride, point.y < Self.height { return .slide(step: index) }
      return nil
    }

    private func click(at point: CGPoint) {
      switch hit(at: point) {
      case .note(let note, let step): setNote(note, at: step)
      case .accent(let step): edit(step, "Set Accent") { $0.accent.toggle() }
      case .slide(let step): edit(step, "Set Slide") { $0 = $0.settingSlide(!$0.slide) }
      case nil: break
      }
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

  extension Theme {
    /// A lit 303 note, lighter at its top edge.
    static func bassShading(in rect: CGRect) -> GraphicsContext.Shading {
      .linearGradient(
        Gradient(colors: [Color(red: 1, green: 222 / 255, blue: 150 / 255), three]),
        startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY))
    }
  }
#endif
