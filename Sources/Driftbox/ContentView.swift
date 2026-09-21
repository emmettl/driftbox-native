#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxEngine
  import DriftboxSeq
  import SwiftUI

  struct ContentView: View {
    @Bindable var player: Player

    var body: some View {
      NavigationSplitView {
        List(
          player.entries,
          selection: Binding(get: { player.current }, set: { if let entry = $0 { player.open(entry) } })
        ) { entry in
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.name).font(.headline)
            Text(entry.blurb).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          }
          .tag(entry)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
      } detail: {
        VStack(spacing: 0) {
          TransportBar(player: player)
          Divider()
          if let song = player.song {
            HStack(alignment: .top, spacing: 0) {
              Sequencer(player: player, song: song)
              Divider()
              VStack(spacing: 0) {
                if let id = player.selectedVoice, let voice = voice(id: id) {
                  VoicePanel(
                    player: player, voice: voice, params: song.kit.params[id] ?? VoiceParams(),
                    sends: song.kit.sends[id] ?? SendLevels())
                } else {
                  FxPanel(player: player, fx: song.fx)
                }
                Divider()
                KaossPad(player: player).frame(width: 220, height: 160).padding(12)
                Spacer()
              }
            }
          } else {
            ContentUnavailableView("Pick a song", systemImage: "music.note.list")
          }
        }
      }
      .overlay(alignment: .bottom) {
        if let error = player.error {
          Text(error).padding(8).background(.red.opacity(0.8)).foregroundStyle(.white).cornerRadius(6)
            .padding()
        }
      }
    }
  }

  struct TransportBar: View {
    let player: Player

    var body: some View {
      HStack(spacing: 16) {
        Button {
          player.toggle()
        } label: {
          Image(systemName: player.isPlaying ? "stop.fill" : "play.fill").frame(width: 24)
        }
        .keyboardShortcut(.space, modifiers: [])
        .disabled(player.song == nil)
        VStack(alignment: .leading) {
          Text(player.current?.name ?? "—").font(.headline)
          if let position = player.position {
            Text("bar \(position.bar + 1) · step \(position.step + 1) · \(position.pattern?.name ?? "")")
              .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          }
        }
        Spacer()
        if let song = player.song {
          Text("\(Int(song.bpm)) bpm").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
      }
      .padding(12)
    }
  }

  /// The step grid for the pattern the transport is in: one row per drum voice that the song
  /// uses, the playhead on the current step, a click cycling a step off, on, accent.
  struct Sequencer: View {
    let player: Player
    let song: Song

    var pattern: DriftboxSeq.Pattern? { player.position?.pattern ?? song.patterns.first }
    var steps: [Int] { (0..<(pattern?.length ?? 0)).map { $0 } }

    var body: some View {
      if let pattern {
        let playhead = player.position?.step ?? -1
        let voices = allVoices.filter { pattern.tracks[$0.id] != nil }
        ScrollView {
          Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(voices, id: \.id) { voice in
              GridRow {
                Button(voice.name) {
                  player.selectedVoice = player.selectedVoice == voice.id ? nil : voice.id
                }
                .buttonStyle(.plain)
                .font(.caption.weight(player.selectedVoice == voice.id ? .bold : .regular))
                .frame(width: 90, alignment: .leading)
                ForEach(steps, id: \.self) { index in
                  StepButton(
                    value: pattern.step(voice.id, at: index), playing: index == playhead,
                    onBeat: index % 4 == 0
                  ) {
                    cycle(voice.id, at: index, in: pattern.id)
                  }
                }
              }
            }
          }
          .padding(12)
        }
      }
    }

    func cycle(_ voiceId: String, at index: Int, in patternId: String) {
      player.edit { song in
        guard let at = song.patterns.firstIndex(where: { $0.id == patternId }) else { return }
        song.patterns[at] = song.patterns[at].cyclingStep(voiceId, at: index)
      }
    }
  }

  struct StepButton: View {
    let value: StepValue
    let playing: Bool
    let onBeat: Bool
    let action: () -> Void

    var body: some View {
      Button(action: action) {
        RoundedRectangle(cornerRadius: 3)
          .fill(color)
          .frame(width: 22, height: 22)
          .overlay(
            RoundedRectangle(cornerRadius: 3).stroke(onBeat ? Color.primary.opacity(0.3) : Color.clear))
      }
      .buttonStyle(.plain)
    }

    var color: Color {
      switch value {
      case .off: playing ? Color.orange.opacity(0.35) : Color.secondary.opacity(0.15)
      case .on: playing ? Color.orange : Color.orange.opacity(0.6)
      case .accent: playing ? Color.red : Color.red.opacity(0.7)
      }
    }
  }
#endif
