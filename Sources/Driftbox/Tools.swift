#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxDSP
  import DriftboxSeq
  import SwiftUI

  /// Which pattern the grid shows: the one playing, or one chosen to edit. And the pattern list's
  /// tools, and the song's tempo and swing.
  struct PatternBar: View {
    let player: Player
    let song: Song

    var body: some View {
      HStack(spacing: 10) {
        Picker(
          "Pattern",
          selection: Binding(get: { player.editing ?? "" }, set: { player.editing = $0.isEmpty ? nil : $0 })
        ) {
          Text("follow").tag("")
          ForEach(song.patterns, id: \.id) { pattern in Text(pattern.name).tag(pattern.id) }
        }
        .frame(width: 180)
        Button("Add") { player.edit { song in song = song.addingPattern().song } }
        Button("Duplicate") {
          guard let id = player.editing ?? player.position?.pattern?.id else { return }
          player.edit { song in
            let result = song.duplicatingPattern(id)
            song = result.song
            player.editing = result.id
          }
        }
        Button("Remove") {
          guard let id = player.editing ?? player.position?.pattern?.id else { return }
          player.edit { song in song = song.removingPattern(id) }
          player.editing = nil
        }
        .disabled(song.patterns.count < 2)
        Spacer()
        Stepper(
          "\(Int(song.bpm)) bpm",
          value: Binding(
            get: { song.bpm }, set: { value in player.edit { $0.bpm = max(20, min(300, value)) } }), step: 1
        )
        .font(.caption.monospacedDigit())
        HStack(spacing: 4) {
          Text("swing").font(.caption)
          Slider(
            value: Binding(get: { song.swing }, set: { value in player.edit { $0.swing = value } }), in: 0...1
          )
          .frame(width: 100)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
  }

  /// What can be done to one drum lane, as a menu on its name.
  struct LaneMenu: View {
    let player: Player
    let pattern: DriftboxSeq.Pattern
    let voiceId: String
    let label: () -> AnyView

    var body: some View {
      Menu {
        Button("Rotate left") { apply { $0.rotatingTrack(voiceId, by: -1) } }
        Button("Rotate right") { apply { $0.rotatingTrack(voiceId, by: 1) } }
        Button("Randomise") { apply { $0.randomisingTrack(voiceId, random: chance()) } }
        Button("Alter") { apply { $0.alteringTrack(voiceId, random: chance()) } }
        Button("Clear") { apply { $0.clearingTrack(voiceId) } }
        Menu("Loop length") {
          ForEach([1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 24, 32].filter { $0 <= pattern.length }, id: \.self) {
            length in
            Button(length == pattern.length ? "\(length) (full)" : "\(length)") {
              apply { $0.settingTrackLength(voiceId, to: length) }
            }
          }
        }
      } label: {
        label()
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }

    func apply(_ change: @escaping (DriftboxSeq.Pattern) -> DriftboxSeq.Pattern) {
      player.edit { song in
        guard let at = song.patterns.firstIndex(where: { $0.id == pattern.id }) else { return }
        song.patterns[at] = change(song.patterns[at])
      }
    }
  }

  /// The 303 line's menu.
  struct BassMenu: View {
    let player: Player
    let pattern: DriftboxSeq.Pattern
    let voiceId: String

    var body: some View {
      Menu {
        Button("Rotate left") { apply { $0.rotatingBassLine(voiceId, by: -1) } }
        Button("Rotate right") { apply { $0.rotatingBassLine(voiceId, by: 1) } }
        Button("Up an octave") { apply { $0.transposingBassLine(voiceId, by: 12) } }
        Button("Down an octave") { apply { $0.transposingBassLine(voiceId, by: -12) } }
        Button("Up a semitone") { apply { $0.transposingBassLine(voiceId, by: 1) } }
        Button("Down a semitone") { apply { $0.transposingBassLine(voiceId, by: -1) } }
        Button("Randomise") { apply { $0.randomisingBassLine(voiceId, random: chance()) } }
        Button("Alter") { apply { $0.alteringBassLine(voiceId, random: chance()) } }
        Button("Clear") { apply { $0.clearingBassLine(voiceId) } }
      } label: {
        Text(voiceId == "303.a" ? "303 A" : "303 B").font(.headline)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }

    func apply(_ change: @escaping (DriftboxSeq.Pattern) -> DriftboxSeq.Pattern) {
      player.edit { song in
        guard let at = song.patterns.firstIndex(where: { $0.id == pattern.id }) else { return }
        song.patterns[at] = change(song.patterns[at])
      }
    }
  }

  /// Chance, from the engine's own generator seeded by the clock.
  func chance() -> RandomSource {
    var stream = SeededRandom(seed: UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 1000)))
    return { stream.next() }
  }
#endif
