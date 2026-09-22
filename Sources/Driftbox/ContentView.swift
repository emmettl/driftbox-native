#if canImport(SwiftUI) && canImport(AVFoundation)
  import AppKit
  import DriftboxDocument
  import DriftboxEngine
  import DriftboxSeq
  import SwiftUI
  import UniformTypeIdentifiers

  struct ContentView: View {
    @Bindable var player: Player
    @Environment(\.undoManager) private var undoManager

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
            PatternBar(player: player, song: song)
            Divider()
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
      .onChange(of: undoManager, initial: true) { _, manager in player.undoManager = manager }
      .modifier(Keys(player: player))
      .focusable()
      .toolbar {
        ToolbarItemGroup {
          Button("Open…") { openFile() }.keyboardShortcut("o")
          Button("Save…") { saveFile() }.keyboardShortcut("s").disabled(player.song == nil)
          Button("Export Mix…") { exportMix() }.keyboardShortcut("e").disabled(player.song == nil)
          Button("Export Stems…") { exportStems() }.disabled(player.song == nil)
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

  extension ContentView {
    func openFile() {
      let panel = NSOpenPanel()
      panel.allowedContentTypes = [.json]
      panel.allowsMultipleSelection = false
      if panel.runModal() == .OK, let url = panel.url { player.open(file: url) }
    }

    /// The whole song, offline, to a WAV file: the same render `driftbox-render` makes.
    func exportMix() {
      guard let song = player.song else { return }
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.wav]
      panel.nameFieldStringValue = (player.current?.name ?? "song") + ".wav"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      let sampleRate = player.sampleRate
      Task.detached {
        let audio = SongRenderer.render(song, options: .init(sampleRate: sampleRate))
        try? WAV.data(audio, sampleRate: sampleRate).write(to: url)
      }
    }

    /// One WAV per voice the song uses, into a folder: each voice alone with its sends.
    func exportStems() {
      guard let song = player.song else { return }
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.canCreateDirectories = true
      panel.prompt = "Export Here"
      guard panel.runModal() == .OK, let folder = panel.url else { return }
      let sampleRate = player.sampleRate
      let name = player.current?.name ?? "song"
      Task.detached {
        for voiceId in SongRenderer.voicesUsed(song) {
          var options = SongRenderer.Options(sampleRate: sampleRate)
          options.only = [voiceId]
          let audio = SongRenderer.render(song, options: options)
          let file = folder.appendingPathComponent("\(name) - \(voiceId).wav")
          try? WAV.data(audio, sampleRate: sampleRate).write(to: file)
        }
      }
    }

    func saveFile() {
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.json]
      panel.nameFieldStringValue = (player.current?.name ?? "song") + ".song.json"
      if panel.runModal() == .OK, let url = panel.url { player.save(to: url) }
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
          Arrangement(player: player, song: song)
          Text("\(Int(song.bpm)) bpm").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
      }
      .padding(12)
    }
  }

  /// The chain, one box per entry, the one playing lit; a click jumps to its first bar.
  struct Arrangement: View {
    let player: Player
    let song: Song

    var body: some View {
      let bar = player.position?.bar ?? -1
      HStack(spacing: 3) {
        ForEach(Array(song.chain.enumerated()), id: \.offset) { index, entry in
          let start = song.chain.prefix(index).reduce(0) { $0 + max(1, $1.repeat) }
          let playing = bar >= start && bar < start + max(1, entry.repeat)
          Button {
            player.seek(toBar: start)
          } label: {
            Text(song.pattern(id: entry.pattern)?.name.prefix(6) ?? "?")
              .font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 3)
              .background(playing ? Color.orange : Color.secondary.opacity(0.2)).cornerRadius(3)
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  /// The step grid for the pattern the transport is in: one row per drum voice that the song
  /// uses, the playhead on the current step, a click cycling a step off, on, accent.
  struct Sequencer: View {
    let player: Player
    let song: Song

    var pattern: DriftboxSeq.Pattern? { player.shownPattern }
    var steps: [Int] { (0..<(pattern?.length ?? 0)).map { $0 } }

    var body: some View {
      if let pattern {
        // The playhead only means something on the pattern that is playing.
        let playing = player.position?.pattern?.id == pattern.id
        let playhead = playing ? (player.position?.step ?? -1) : -1
        let voices = allVoices.filter { pattern.tracks[$0.id] != nil }
        ScrollView {
          Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(voices, id: \.id) { voice in
              GridRow {
                let index = allVoices.firstIndex { $0.id == voice.id } ?? -1
                let struck = player.lastHits[index].map { player.engineFrame - $0 < 4800 } ?? false
                HStack(spacing: 2) {
                  Button(voice.name) {
                    player.selectedVoice = player.selectedVoice == voice.id ? nil : voice.id
                  }
                  .buttonStyle(.plain)
                  .font(.caption.weight(player.selectedVoice == voice.id ? .bold : .regular))
                  .foregroundStyle(struck ? Color.orange : Color.primary)
                  LaneMenu(player: player, pattern: pattern, voiceId: voice.id) {
                    AnyView(Image(systemName: "ellipsis.circle").font(.caption).foregroundStyle(.secondary))
                  }
                }
                .frame(width: 110, alignment: .leading)
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
          ForEach(["303.a", "303.b"].filter { pattern.bass[$0] != nil }, id: \.self) { voiceId in
            BassGrid(player: player, pattern: pattern, voiceId: voiceId, playhead: playhead).padding(12)
          }
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
