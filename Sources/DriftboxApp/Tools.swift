#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxDSP
  import DriftboxSeq
  import SwiftUI

  /// Which pattern the grid shows: the one playing, followed, or one chosen to edit, as a row
  /// of chips with the playing one marked. And the pattern list's tools.
  struct PatternBar: View {
    let player: Player
    let song: Song

    var body: some View {
      let shown = player.shownPattern?.id
      let playing = player.isPlaying ? player.position?.pattern?.id : nil
      HStack(spacing: 8) {
        FieldLabel("Pattern")
        Button {
          player.editing = nil
        } label: {
          Label("follow", systemImage: "arrow.triangle.2.circlepath").labelStyle(.titleAndIcon)
        }
        .buttonStyle(.chip(on: player.editing == nil))
        .help("Show whichever pattern is playing")
        Rectangle().fill(Theme.edge).frame(width: 1, height: 18)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 5) {
            ForEach(song.patterns, id: \.id) { pattern in
              Button {
                player.editing = pattern.id
              } label: {
                HStack(spacing: 5) {
                  if pattern.id == playing {
                    Circle().fill(Theme.live).frame(width: 5, height: 5).shadow(color: Theme.live, radius: 3)
                  }
                  Text(pattern.name).lineLimit(1)
                }
              }
              .buttonStyle(
                .chip(on: pattern.id == shown, tint: player.editing == nil ? Theme.live : Theme.eight))
            }
          }
          .padding(.vertical, 6)
          .padding(.horizontal, 2)
        }
        // Chips that run off the end fade rather than being cut.
        .mask(
          HStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(
              width: 24)
          })
        Spacer(minLength: 4)
        HStack(spacing: 4) {
          Button {
            player.edit("Add Pattern") { song in song = song.addingPattern().song }
          } label: {
            Image(systemName: "plus")
          }
          .help("Add a pattern")
          Button {
            guard let id = shown else { return }
            player.edit("Duplicate Pattern") { song in
              let result = song.duplicatingPattern(id)
              song = result.song
              player.editing = result.id
            }
          } label: {
            Image(systemName: "plus.square.on.square")
          }
          .help("Duplicate this pattern")
          Button {
            guard let id = shown else { return }
            player.edit("Remove Pattern") { song in song = song.removingPattern(id) }
            player.editing = nil
          } label: {
            Image(systemName: "trash")
          }
          .help("Remove this pattern")
          .disabled(song.patterns.count < 2)
        }
        .buttonStyle(.chip)
      }
      .padding(.horizontal, 14)
      .frame(height: 44)
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
        Button("Rotate left") { apply("Rotate Left") { $0.rotatingTrack(voiceId, by: -1) } }
        Button("Rotate right") { apply("Rotate Right") { $0.rotatingTrack(voiceId, by: 1) } }
        Button("Randomise") { apply("Randomise") { $0.randomisingTrack(voiceId, random: chance()) } }
        Button("Alter") { apply("Alter") { $0.alteringTrack(voiceId, random: chance()) } }
        Button("Clear") { apply("Clear Lane") { $0.clearingTrack(voiceId) } }
        Menu("Loop length") {
          ForEach([1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 24, 32].filter { $0 <= pattern.length }, id: \.self) {
            length in
            Button(length == pattern.length ? "\(length) (full)" : "\(length)") {
              apply("Set Loop Length") { $0.settingTrackLength(voiceId, to: length) }
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

    func apply(_ name: String, _ change: @escaping (DriftboxSeq.Pattern) -> DriftboxSeq.Pattern) {
      player.edit(name) { song in
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
        Button("Rotate left") { apply("Rotate Left") { $0.rotatingBassLine(voiceId, by: -1) } }
        Button("Rotate right") { apply("Rotate Right") { $0.rotatingBassLine(voiceId, by: 1) } }
        Button("Up an octave") { apply("Transpose") { $0.transposingBassLine(voiceId, by: 12) } }
        Button("Down an octave") { apply("Transpose") { $0.transposingBassLine(voiceId, by: -12) } }
        Button("Up a semitone") { apply("Transpose") { $0.transposingBassLine(voiceId, by: 1) } }
        Button("Down a semitone") { apply("Transpose") { $0.transposingBassLine(voiceId, by: -1) } }
        Button("Randomise") { apply("Randomise") { $0.randomisingBassLine(voiceId, random: chance()) } }
        Button("Alter") { apply("Alter") { $0.alteringBassLine(voiceId, random: chance()) } }
        Button("Clear") { apply("Clear Line") { $0.clearingBassLine(voiceId) } }
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Theme.dim)
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }

    func apply(_ name: String, _ change: @escaping (DriftboxSeq.Pattern) -> DriftboxSeq.Pattern) {
      player.edit(name) { song in
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
