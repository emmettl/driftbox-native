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
        SongList(player: player, files: files)
          .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
      } detail: {
        ZStack {
          Backdrop(stage: stage, running: player.showsVisuals)
          if let song = player.song {
            VStack(spacing: 12) {
              SongStrip(player: player, song: song)
              HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                  PatternBar(player: player, song: song)
                  Rectangle().fill(Theme.edge).frame(height: 1)
                  Sequencer(player: player, song: song)
                }
                .panel()
                Inspector(player: player, song: song)
                  .frame(width: 292)
              }
            }
            .padding(14)
          } else {
            EmptyWindow(player: player, files: files)
          }
        }
        .frame(minWidth: 820, minHeight: 560)
        .toolbar { TransportToolbar(player: player, files: files, showsVisuals: $showsVisuals) }
        // No grey band: the indigo, and the visuals, run up under the transport.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
      }
      .preferredColorScheme(.dark)
      .tint(Theme.nine)
      // The window's own ground is the indigo, so the sidebar's glass is tinted by it rather
      // than by the system's grey.
      .containerBackground(Theme.ground, for: .window)
      .onChange(of: undoManager, initial: true) { _, manager in player.undoManager = manager }
      .modifier(Keys(player: player))
      .modifier(Preferences(player: player))
      .focusable()
      .focusEffectDisabled()
      // The window's title is the song's, and the rest of what a document window says about
      // itself — its file, its proxy icon, its edited dot — is AppKit's to say.
      .navigationTitle(player.documentName)
      .navigationSubtitle(player.current.map { SongRow.genre(of: $0) } ?? "")
      .background(WindowIdentity(player: player, files: files))
      // A song dropped on the window opens, as it would on any Mac application that holds one.
      .dropDestination(for: URL.self) { urls, _ in
        guard let url = urls.first(where: \.isFileURL) else { return false }
        files.open(url)
        return true
      }
      .overlay(alignment: .bottom) {
        if let error = player.error ?? player.outputError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(Theme.mono(11))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Color(red: 0.55, green: 0.1, blue: 0.2).opacity(0.9)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            .padding(18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(.spring(response: 0.35, dampingFraction: 0.8), value: player.error ?? player.outputError)
    }
  }

  /// The visuals, behind everything, dimmed so the grid stays readable — as the web app has
  /// them. The same frame the visuals window shows, filling the window rather than boxed in it.
  struct Backdrop: View {
    let stage: Stage
    let running: Bool

    var body: some View {
      ZStack {
        Theme.ground
        if running {
          StageView(stage: stage, role: .preview)
            .opacity(0.42)
            .transition(.opacity)
        }
        // Darker toward the foot, where the grid is densest.
        LinearGradient(
          colors: [Theme.ground.opacity(0), Theme.ground.opacity(0.55)], startPoint: .top, endPoint: .bottom)
      }
      .ignoresSafeArea()
      .animation(.easeInOut(duration: 0.5), value: running)
    }
  }

  /// With no song open: the window says what to do, in its own voice.
  struct EmptyWindow: View {
    let player: Player
    let files: SongFiles

    var body: some View {
      VStack(spacing: 14) {
        Text("DRIFTBOX").font(Theme.mono(28, .bold)).tracking(8).foregroundStyle(Theme.ink)
          .shadow(color: Theme.eight.opacity(0.5), radius: 18)
        Text("an 808, a 909 and two 303s").font(Theme.mono(12)).foregroundStyle(Theme.dim)
        HStack(spacing: 8) {
          Button("Open a song…") { files.openPanel() }
            .buttonStyle(.chip)
          if let first = player.entries.first {
            Button("Play \(first.name)") {
              files.open(first)
              player.toggle()
            }
            .buttonStyle(.chip(on: true))
          }
        }
        .padding(.top, 8)
        Text("or pick one from the list").font(Theme.mono(10)).foregroundStyle(Theme.dim.opacity(0.7))
      }
    }
  }

  // MARK: - The song list

  /// The songs, as a list of rows drawn here rather than by the system, so the chosen one lights
  /// in the instrument's colours instead of the system's blue. The arrow keys still walk it.
  struct SongList: View {
    let player: Player
    let files: SongFiles
    @FocusState private var focused: Bool

    var body: some View {
      ScrollViewReader { scroller in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            FieldLabel("Songs").padding(.horizontal, 12).padding(.bottom, 4)
            ForEach(player.entries) { entry in
              let chosen = player.current?.id == entry.id
              Button {
                files.open(entry)
              } label: {
                SongRow(entry: entry, playing: player.isPlaying && chosen, chosen: chosen)
              }
              .buttonStyle(.plain)
              .id(entry.id)
            }
          }
          .padding(.horizontal, 8)
          .padding(.bottom, 6)
        }
        .scrollIndicators(.never)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.upArrow) { step(-1) }
        .onChange(of: player.current?.id) { _, id in
          guard let id else { return }
          withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(id) }
        }
      }
      .background(Theme.ground.opacity(0.7).ignoresSafeArea())
    }

    private func step(_ by: Int) -> KeyPress.Result {
      let entries = player.entries
      guard !entries.isEmpty else { return .ignored }
      let at = entries.firstIndex { $0.id == player.current?.id } ?? (by > 0 ? -1 : entries.count)
      let next = min(entries.count - 1, max(0, at + by))
      if next != at { files.open(entries[next]) }
      return .handled
    }
  }

  struct SongRow: View {
    let entry: CatalogueEntry
    let playing: Bool
    var chosen = false
    @State private var hovering = false

    /// The first clause of the blurb — "Acid house" — which is what the song is.
    static func genre(of entry: CatalogueEntry) -> String {
      String(entry.blurb.split(separator: " — ", maxSplits: 1).first ?? "")
    }

    /// The rest — "126bpm, straight, 303 doing its thing".
    static func detail(of entry: CatalogueEntry) -> String {
      let parts = entry.blurb.split(separator: " — ", maxSplits: 1)
      return parts.count > 1 ? String(parts[1]) : ""
    }

    var body: some View {
      let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(entry.name).font(.system(size: 13, weight: .semibold))
            .foregroundStyle(chosen ? Theme.ink : Theme.ink.opacity(0.88))
          if playing {
            Image(systemName: "waveform")
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(Theme.nine)
              .symbolEffect(.variableColor.iterative, isActive: true)
              .transition(.scale.combined(with: .opacity))
          }
        }
        Text(Self.genre(of: entry).uppercased())
          .font(Theme.mono(9, .medium)).tracking(0.6).foregroundStyle(Theme.eight.opacity(chosen ? 1 : 0.8))
        Text(Self.detail(of: entry))
          .font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(2)
          .multilineTextAlignment(.leading)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(shape.fill(chosen ? Theme.eight.opacity(0.14) : Color.white.opacity(hovering ? 0.05 : 0)))
      .overlay(shape.strokeBorder(chosen ? Theme.eight.opacity(0.4) : Color.clear))
      .contentShape(shape)
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.12), value: hovering)
      .animation(.spring(response: 0.3, dampingFraction: 0.7), value: playing)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(chosen ? .isSelected : [])
    }
  }

  // MARK: - The transport

  /// The toolbar is the transport: play, the position and tempo in a display of their own, the
  /// clock switches, and the visuals and export on the right.
  struct TransportToolbar: ToolbarContent {
    let player: Player
    let files: SongFiles
    @Binding var showsVisuals: Bool

    var body: some ToolbarContent {
      ToolbarItemGroup(placement: .navigation) {
        PlayButton(player: player)
        Button {
          player.seek(toStep: 0)
        } label: {
          Label("Return to Start", systemImage: "backward.end.fill")
        }
        .help("Return to the start of the song")
        .disabled(player.song == nil)
      }
      ToolbarItem(placement: .principal) {
        TransportDisplay(player: player)
      }
      ToolbarItemGroup(placement: .primaryAction) {
        Toggle(isOn: $showsVisuals) {
          Label(
            "Visuals",
            systemImage: showsVisuals ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack")
        }
        .help(showsVisuals ? "Stop the visuals behind the editor" : "Run the visuals behind the editor")
        Menu {
          Button("Export Mix…") { files.exportMix() }
          Button("Export Stems…") { files.exportStems() }
        } label: {
          Label("Export", systemImage: "square.and.arrow.up")
        }
        .help("Export the song as audio")
        .disabled(player.song == nil)
      }
    }
  }

  /// Play, lit and glowing while it runs.
  struct PlayButton: View {
    let player: Player

    var body: some View {
      Button {
        player.toggle()
      } label: {
        Label(player.isPlaying ? "Stop" : "Play", systemImage: player.isPlaying ? "stop.fill" : "play.fill")
          .foregroundStyle(player.isPlaying ? Theme.nine : Theme.ink)
          .shadow(color: player.isPlaying ? Theme.nine.opacity(0.8) : .clear, radius: 6)
          .contentTransition(.symbolEffect(.replace))
      }
      .keyboardShortcut(.space, modifiers: [])
      .disabled(player.song == nil)
      .help(player.isPlaying ? "Stop (Space)" : "Play (Space)")
    }
  }

  /// Where the song is and how fast: four beat lights, the bar and step, the pattern, then the
  /// tempo and swing, which are dragged like the knobs are. And the two clock switches, which
  /// are performance decisions and so belong beside the tempo rather than in Settings.
  struct TransportDisplay: View {
    let player: Player
    // The clock is remembered between launches, so this writes the preference and the window
    // mirrors it onto the player; the menu's own switch writes the same one.
    @AppStorage(Defaults.sendsClock) private var sendsClock = false

    var body: some View {
      let position = player.position
      HStack(spacing: 14) {
        BeatLights(step: player.isPlaying ? position?.step : nil)
        VStack(alignment: .leading, spacing: 0) {
          Text(position.map { String(format: "%03d.%02d", $0.bar + 1, $0.step + 1) } ?? "---.--")
            .font(Theme.mono(14, .semibold).monospacedDigit())
            .foregroundStyle(player.isPlaying ? Theme.ink : Theme.ink.opacity(0.7))
          Text((position?.pattern?.name ?? "—").uppercased())
            .font(Theme.mono(8.5, .medium)).tracking(0.8).foregroundStyle(Theme.dim).lineLimit(1)
        }
        .frame(width: 84, alignment: .leading)
        if let song = player.song {
          Rectangle().fill(Theme.edge).frame(width: 1, height: 22)
          if let followed = player.followedBPM {
            HStack(spacing: 5) {
              FieldLabel("Ext")
              Text(String(format: "%.1f", followed)).font(Theme.mono(14, .semibold).monospacedDigit())
                .foregroundStyle(Theme.three)
            }
            .help("Following an external MIDI clock")
          } else {
            DragNumber(
              label: "BPM", value: song.bpm, range: 20...300, perPoint: 0.5,
              format: { "\(Int($0.rounded()))" }
            ) { value in player.edit("Set Tempo") { $0.bpm = value.rounded() } }
          }
          DragNumber(
            label: "Swing", value: song.swing * 100, range: 0...100, perPoint: 0.5,
            format: { "\(Int($0.rounded()))" }
          ) { value in player.edit("Set Swing") { $0.swing = value.rounded() / 100 } }
          Rectangle().fill(Theme.edge).frame(width: 1, height: 22)
          HStack(spacing: 4) {
            Button("sync") { player.followsClock.toggle() }
              .buttonStyle(.chip(on: player.followsClock, tint: Theme.three, size: 10))
              .help("Follow an external MIDI clock: tempo, start, stop and position")
            // Where the clock goes is a setting, made once; whether it is going is a
            // performance decision, made often, and that is the only part that is here.
            Button("clock") { sendsClock.toggle() }
              .buttonStyle(.chip(on: sendsClock, tint: Theme.nine, size: 10))
              .help("Send MIDI clock out. Where it goes is in Settings.")
          }
        }
      }
      .padding(.horizontal, 14)
      .frame(height: 38)
      .fixedSize()
    }
  }

  /// Four lights, one to a beat of the bar, the current one lit.
  struct BeatLights: View {
    let step: Int?

    var body: some View {
      HStack(spacing: 5) {
        ForEach(0..<4, id: \.self) { beat in
          let lit = step.map { $0 / 4 % 4 == beat } ?? false
          let downbeat = lit && beat == 0
          Circle()
            .fill(lit ? (downbeat ? Theme.eight : Theme.nine) : Color.white.opacity(0.14))
            .frame(width: 7, height: 7)
            .shadow(color: lit ? (downbeat ? Theme.eight : Theme.nine) : .clear, radius: 5)
            .animation(lit ? nil : .easeOut(duration: 0.25), value: lit)
        }
      }
    }
  }

  /// A number set by dragging it up and down, like a knob with no knob: how a hardware tempo
  /// display is set with a data wheel. Option makes it fine; the song only changes on release.
  struct DragNumber: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var perPoint = 0.5
    let format: (Double) -> String
    let commit: (Double) -> Void

    @State private var dragging: Double?
    @State private var from = 0.0
    @State private var hovering = false

    var body: some View {
      HStack(spacing: 6) {
        FieldLabel(label)
        Text(format(dragging ?? value))
          .font(Theme.mono(14, .semibold).monospacedDigit())
          .foregroundStyle(dragging != nil ? Theme.nine : hovering ? Theme.ink : Theme.ink.opacity(0.9))
          .shadow(color: dragging != nil ? Theme.nine.opacity(0.6) : .clear, radius: 5)
          .frame(minWidth: 30, alignment: .trailing)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(
        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovering || dragging != nil ? 0.07 : 0))
      )
      .contentShape(Rectangle())
      .onHover { inside in
        hovering = inside
        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
      }
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { gesture in
            if dragging == nil { from = value }
            let fine = NSEvent.modifierFlags.contains(.option)
            let moved = -gesture.translation.height * perPoint * (fine ? 0.2 : 1)
            dragging = min(range.upperBound, max(range.lowerBound, from + moved))
          }
          .onEnded { _ in
            if let dragging, format(dragging) != format(value) { commit(dragging) }
            dragging = nil
          }
      )
      .help("Drag up or down to change \(label.lowercased()); hold Option for fine steps")
      .accessibilityElement()
      .accessibilityLabel(label)
      .accessibilityValue(format(value))
      .accessibilityAdjustableAction { direction in
        commit(min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? 1 : -1))))
      }
    }
  }

  // MARK: - The song

  /// The chain, drawn to scale: one block per entry, as wide as its bars, coloured by pattern so
  /// the song's shape shows — the verse that comes back, the break in the middle. The playing
  /// block lights and fills as it goes; a click jumps to its first bar.
  struct SongStrip: View {
    let player: Player
    let song: Song

    var body: some View {
      let blocks = SongStrip.blocks(song)
      let total = blocks.last.map { $0.start + $0.bars } ?? 0
      let bar = player.position?.bar ?? -1
      let step = player.position?.step ?? 0
      let length = player.position?.pattern?.length ?? 16
      VStack(alignment: .leading, spacing: 7) {
        HStack {
          FieldLabel("Song")
          Spacer()
          Text("\(total) bars").font(Theme.mono(9)).foregroundStyle(Theme.dim)
        }
        GeometryReader { geometry in
          let gap = 3.0
          let room = geometry.size.width - gap * Double(max(0, blocks.count - 1))
          HStack(spacing: gap) {
            ForEach(blocks, id: \.index) { block in
              let playing = bar >= block.start && bar < block.start + block.bars
              let progress =
                playing
                ? (Double(bar - block.start) + Double(step) / Double(max(1, length))) / Double(block.bars) : 0
              ChainBlock(
                name: block.name, bars: block.bars, tint: Theme.patternColor(block.colour), current: playing,
                running: player.isPlaying, progress: progress
              ) { player.seek(toBar: block.start) }
              .frame(width: max(4, room * Double(block.bars) / Double(max(1, total))))
            }
          }
        }
        .frame(height: 30)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .panel()
    }

    struct Block {
      let index: Int
      let name: String
      let start: Int
      let bars: Int
      /// Which colour: patterns in order of first appearance, so the same pattern is always
      /// the same colour within a song.
      let colour: Int
    }

    static func blocks(_ song: Song) -> [Block] {
      var start = 0
      var colours: [String: Int] = [:]
      return song.chain.enumerated().map { index, entry in
        let bars = max(1, entry.repeat)
        let colour = colours[entry.pattern] ?? colours.count
        colours[entry.pattern] = colour
        defer { start += bars }
        return Block(
          index: index, name: song.pattern(id: entry.pattern)?.name ?? "?", start: start, bars: bars,
          colour: colour)
      }
    }
  }

  struct ChainBlock: View {
    let name: String
    let bars: Int
    let tint: Color
    /// Where the transport is.
    let current: Bool
    /// And whether it is moving: stopped, the block is only marked, not lit.
    let running: Bool
    let progress: Double
    let action: () -> Void
    @State private var hovering = false

    var playing: Bool { current && running }

    var body: some View {
      Button(action: action) {
        GeometryReader { geometry in
          let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
          ZStack(alignment: .leading) {
            shape.fill(tint.opacity(playing ? 0.28 : hovering ? 0.2 : 0.12))
            if playing {
              Rectangle().fill(tint.opacity(0.35))
                .frame(width: geometry.size.width * min(1, max(0, progress)))
            }
            if geometry.size.width > 34 {
              HStack(spacing: 4) {
                Text(name).font(Theme.mono(10, playing ? .semibold : .regular)).lineLimit(1)
                  .foregroundStyle(playing ? Theme.ink : Theme.ink.opacity(0.75))
                if bars > 1, geometry.size.width > 70 {
                  Text("×\(bars)").font(Theme.mono(9)).foregroundStyle(Theme.dim)
                }
              }
              .padding(.horizontal, 7)
            }
          }
          .clipShape(shape)
          .overlay(shape.strokeBorder(tint.opacity(playing ? 0.95 : current || hovering ? 0.6 : 0.3)))
          .shadow(color: playing ? tint.opacity(0.55) : .clear, radius: 8)
        }
      }
      .buttonStyle(StepPress())
      .onHover { hovering = $0 }
      .help("\(name), \(bars) bar\(bars == 1 ? "" : "s") — click to play from here")
      .animation(.easeOut(duration: 0.15), value: hovering)
    }
  }

  extension Theme {
    /// A pattern's colour in the song strip, by order of first appearance.
    static func patternColor(_ index: Int) -> Color {
      let palette = [
        eight, nine, three, violet, Color(red: 106 / 255, green: 168 / 255, blue: 1),
        Color(red: 1, green: 138 / 255, blue: 106 / 255),
      ]
      return palette[index % palette.count]
    }
  }
#endif
