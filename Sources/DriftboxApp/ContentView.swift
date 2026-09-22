#if canImport(SwiftUI) && canImport(AVFoundation)
  import AppKit
  import DriftboxDocument
  import DriftboxEngine
  import DriftboxHost
  import DriftboxSeq
  import SwiftUI
  import UniformTypeIdentifiers

  public struct ContentView: View {
    @Bindable var player: Player
    let stage: Stage
    @Environment(\.undoManager) private var undoManager
    @AppStorage(Defaults.visuals) private var showsVisuals = true

    public init(player: Player, stage: Stage) {
      self.player = player
      self.stage = stage
    }

    /// The File menu's own actions, which the toolbar shares rather than repeats.
    var files: SongFiles { SongFiles(player: player) }

    public var body: some View {
      NavigationSplitView {
        List(
          player.entries,
          selection: Binding(get: { player.current }, set: { if let entry = $0 { files.open(entry) } })
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
            if player.showsVisuals {
              StageView(stage: stage, role: .preview)
                .frame(height: 200)
                // Said plainly, because a letterboxed picture with nothing to explain it looks
                // like a pane that has been drawn at the wrong size.
                .overlay(alignment: .topTrailing) {
                  if stage.outputOpen {
                    Text("Preview of the visuals window")
                      .font(.caption2).foregroundStyle(.white.opacity(0.7))
                      .padding(.horizontal, 6).padding(.vertical, 3)
                      .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                      .padding(8)
                  }
                }
              Divider()
            }
            PatternBar(player: player, song: song)
            Divider()
            HStack(alignment: .top, spacing: 0) {
              Sequencer(player: player, song: song)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
              Divider()
              ScrollView {
                if let id = player.selectedVoice, let voice = voice(id: id) {
                  VoicePanel(
                    player: player, voice: voice, params: song.kit.params[id] ?? VoiceParams(),
                    sends: song.kit.sends[id] ?? SendLevels())
                } else {
                  FxPanel(player: player, fx: song.fx)
                }
                Divider()
                KaossPad(player: player).frame(width: 220, height: 160).padding(12)
              }
              .frame(width: 244)
            }
          } else {
            ContentUnavailableView("Pick a song", systemImage: "music.note.list")
          }
        }
      }
      .onChange(of: undoManager, initial: true) { _, manager in player.undoManager = manager }
      .modifier(Keys(player: player))
      .modifier(Preferences(player: player))
      .focusable()
      // The window's title is the song's, and the rest of what a document window says about
      // itself — its file, its proxy icon, its edited dot — is AppKit's to say.
      .navigationTitle(player.documentName)
      .background(WindowIdentity(player: player, files: files))
      // A song dropped on the window opens, as it would on any Mac application that holds one.
      .dropDestination(for: URL.self) { urls, _ in
        guard let url = urls.first(where: \.isFileURL) else { return false }
        files.open(url)
        return true
      }
      .toolbar {
        // No key equivalents here: every one of these is a menu item, and the menu holds the key.
        ToolbarItemGroup {
          Button("Open…") { files.openPanel() }
          Button("Save") { files.save() }.disabled(player.song == nil)
          Button("Export Mix…") { files.exportMix() }.disabled(player.song == nil)
          Button("Export Stems…") { files.exportStems() }.disabled(player.song == nil)
          Toggle("Visuals", isOn: $showsVisuals)
        }
      }
      .overlay(alignment: .bottom) {
        if let error = player.error ?? player.outputError {
          Text(error).padding(8).background(.red.opacity(0.8)).foregroundStyle(.white).cornerRadius(6)
            .padding()
        }
      }
    }
  }

  struct TransportBar: View {
    let player: Player
    // The clock is remembered between launches, so these write the preference and the window
    // mirrors it onto the player; the menu's own switches write the same one.
    @AppStorage(Defaults.sendsClock) private var sendsClock = false

    var body: some View {
      HStack(spacing: 16) {
        Button {
          player.toggle()
        } label: {
          Image(systemName: player.isPlaying ? "stop.fill" : "play.fill").frame(width: 24)
        }
        .keyboardShortcut(.space, modifiers: [])
        .disabled(player.song == nil)
        // The name comes before the chain when there is not room for both: which song this is
        // matters more than seeing every entry of it at once, and the chain scrolls anyway.
        VStack(alignment: .leading) {
          Text(player.current?.name ?? "—").font(.headline).lineLimit(1)
          if let position = player.position {
            Text("bar \(position.bar + 1) · step \(position.step + 1) · \(position.pattern?.name ?? "")")
              .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        .layoutPriority(1)
        Spacer(minLength: 8)
        Toggle("sync", isOn: Binding(get: { player.followsClock }, set: { player.followsClock = $0 }))
          .toggleStyle(.button).font(.caption).fixedSize()
          .help("Follow an external MIDI clock: tempo, start, stop and position")
        if let bpm = player.followedBPM {
          Text(String(format: "← %.1f", bpm)).font(.caption.monospacedDigit()).foregroundStyle(.orange)
        }
        // Where the clock goes is a setting, made once; whether it is going is a performance
        // decision, made often, and that is the only part the transport has room for.
        Toggle("clock", isOn: $sendsClock)
          .toggleStyle(.button).font(.caption).fixedSize()
          .help("Send MIDI clock out: start, six ticks a sixteenth, stop. Where it goes is in Settings.")
        if let song = player.song {
          Arrangement(player: player, song: song)
          Text("\(Int(song.bpm)) bpm").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .fixedSize()
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
      // A long chain scrolls; it never wraps a name onto two lines to fit.
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 3) {
          ForEach(Array(song.chain.enumerated()), id: \.offset) { index, entry in
            let start = song.chain.prefix(index).reduce(0) { $0 + max(1, $1.repeat) }
            let playing = bar >= start && bar < start + max(1, entry.repeat)
            Button {
              player.seek(toBar: start)
            } label: {
              Text(song.pattern(id: entry.pattern)?.name.prefix(6) ?? "?")
                .font(.system(size: 9)).lineLimit(1).fixedSize()
                .padding(.horizontal, 4).padding(.vertical, 3)
                .background(playing ? Color.orange : Color.secondary.opacity(0.2)).cornerRadius(3)
            }
            .buttonStyle(.plain)
          }
        }
      }
      // It gives way before the song's name does, down to enough for a few entries.
      .frame(minWidth: 160, idealWidth: 420, maxWidth: 420)
    }
  }

  /// The step grid for the pattern the transport is in: one row per drum voice that the song
  /// uses, the playhead on the current step, a click cycling a step off, on, accent.
  struct Sequencer: View {
    let player: Player
    let song: Song

    var pattern: DriftboxSeq.Pattern? { player.shownPattern }

    var body: some View {
      if let pattern {
        // The playhead only means something on the pattern that is playing.
        let playing = player.position?.pattern?.id == pattern.id
        let playhead = playing ? (player.position?.step ?? -1) : -1
        let voices = allVoices.filter { pattern.tracks[$0.id] != nil }
        GeometryReader { viewport in
          ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
              Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(voices, id: \.id) { voice in
                  let index = allVoices.firstIndex { $0.id == voice.id } ?? -1
                  Lane(
                    player: player, pattern: pattern, voiceId: voice.id, name: voice.name,
                    struck: player.struck.contains(index), selected: player.selectedVoice == voice.id,
                    playhead: playhead)
                }
              }
              .padding(12)
              ForEach(["303.a", "303.b"].filter { pattern.bass[$0] != nil }, id: \.self) { voiceId in
                BassGrid(player: player, pattern: pattern, voiceId: voiceId, playhead: playhead).padding(12)
              }
            }
            .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
          }
        }
      }
    }

  }

  /// One voice's row of the grid. Its inputs are all plain values, so a step elsewhere, or a
  /// flash on another lane, leaves this one's body alone.
  struct Lane: View {
    let player: Player
    let pattern: DriftboxSeq.Pattern
    let voiceId: String
    let name: String
    let struck: Bool
    let selected: Bool
    let playhead: Int

    var body: some View {
      GridRow {
        HStack(spacing: 2) {
          Button(name) {
            player.selectedVoice = selected ? nil : voiceId
          }
          .buttonStyle(.plain)
          .font(.caption.weight(selected ? .bold : .regular))
          .foregroundStyle(struck ? Color.orange : Color.primary)
          LaneMenu(player: player, pattern: pattern, voiceId: voiceId) {
            AnyView(Image(systemName: "ellipsis.circle").font(.caption).foregroundStyle(.secondary))
          }
        }
        .frame(width: 110, alignment: .leading)
        ForEach(0..<pattern.length, id: \.self) { index in
          StepButton(
            player: player, patternId: pattern.id, voiceId: voiceId, index: index,
            value: pattern.step(voiceId, at: index), playing: index == playhead)
        }
      }
    }
  }

  struct StepButton: View {
    let player: Player
    let patternId: String
    let voiceId: String
    let index: Int
    let value: StepValue
    let playing: Bool
    var onBeat: Bool { index % 4 == 0 }

    var body: some View {
      Button(action: cycle) {
        RoundedRectangle(cornerRadius: 3)
          .fill(color)
          .frame(width: 22, height: 22)
          .overlay(
            RoundedRectangle(cornerRadius: 3).stroke(onBeat ? Color.primary.opacity(0.3) : Color.clear))
      }
      .buttonStyle(.plain)
    }

    func cycle() {
      player.edit("Set Step") { song in
        guard let at = song.patterns.firstIndex(where: { $0.id == patternId }) else { return }
        song.patterns[at] = song.patterns[at].cyclingStep(voiceId, at: index)
      }
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
