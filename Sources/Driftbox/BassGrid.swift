#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxSeq
  import SwiftUI

  /// A 303 line: for each step, whether it sounds, its pitch across two octaves, accent and slide.
  /// Clicking a cell in the pitch rows sets the note there; clicking the note that is already set
  /// pauses it; the two rows underneath toggle accent and slide.
  struct BassGrid: View {
    let player: Player
    let pattern: DriftboxSeq.Pattern
    let voiceId: String
    let playhead: Int

    static let notes = Array((0...24).reversed())
    static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    var steps: [Int] { (0..<pattern.length).map { $0 } }

    var body: some View {
      VStack(alignment: .leading, spacing: 2) {
        BassMenu(player: player, pattern: pattern, voiceId: voiceId)
        Grid(alignment: .leading, horizontalSpacing: 2, verticalSpacing: 1) {
          ForEach(Self.notes, id: \.self) { note in
            GridRow {
              Text(note % 12 == 0 ? "C\(note / 12 + 1)" : Self.names[note % 12])
                .font(.system(size: 9)).frame(width: 24, alignment: .trailing)
              ForEach(steps, id: \.self) { index in
                let step = pattern.bassStep(voiceId, at: index)
                let here = Int(step.note ?? -1) == note
                Rectangle()
                  .fill(cellColor(step: step, here: here, playing: index == playhead))
                  .frame(width: 22, height: 8)
                  .onTapGesture { setNote(note, at: index) }
              }
            }
          }
          GridRow {
            Text("acc").font(.system(size: 9)).frame(width: 24, alignment: .trailing)
            ForEach(steps, id: \.self) { index in
              let step = pattern.bassStep(voiceId, at: index)
              Rectangle().fill(step.accent ? Color.red.opacity(0.8) : Color.secondary.opacity(0.15))
                .frame(width: 22, height: 12)
                .onTapGesture { edit(index) { $0.accent.toggle() } }
            }
          }
          GridRow {
            Text("sld").font(.system(size: 9)).frame(width: 24, alignment: .trailing)
            ForEach(steps, id: \.self) { index in
              let step = pattern.bassStep(voiceId, at: index)
              Rectangle().fill(step.slide ? Color.blue.opacity(0.8) : Color.secondary.opacity(0.15))
                .frame(width: 22, height: 12)
                .onTapGesture { edit(index) { $0 = $0.settingSlide(!$0.slide) } }
            }
          }
        }
      }
    }

    func cellColor(step: BassStep, here: Bool, playing: Bool) -> Color {
      if here { return step.sounds ? (playing ? .orange : .orange.opacity(0.7)) : .orange.opacity(0.25) }
      return playing ? Color.secondary.opacity(0.25) : Color.secondary.opacity(0.08)
    }

    func setNote(_ note: Int, at index: Int) {
      edit(index) { step in
        if Int(step.note ?? -1) == note, step.sounds {
          step = step.settingGate(false)
        } else {
          step.note = Double(note)
          step = step.settingGate(true)
        }
      }
    }

    func edit(_ index: Int, _ change: @escaping (inout BassStep) -> Void) {
      player.edit { song in
        guard let at = song.patterns.firstIndex(where: { $0.id == pattern.id }) else { return }
        var step = song.patterns[at].bassStep(voiceId, at: index)
        change(&step)
        song.patterns[at] = song.patterns[at].settingBassStep(voiceId, at: index, to: step)
      }
    }
  }
#endif
