#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxDSP
  import DriftboxSeq
  import DriftboxSession
  import SwiftUI

  /// Which pattern the grid shows: the one playing, followed, or one chosen to edit, as a row
  /// of chips with the playing one marked. Each chip's context menu holds what can be done to
  /// that pattern; double-clicking one renames it. Then the pattern list's tools.
  struct PatternBar: View {
    let player: Session
    let song: Song
    @State private var renaming: String?
    @State private var name = ""

    var body: some View {
      let shown = player.shownPattern
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
              chip(pattern, shown: pattern.id == shown?.id, playing: pattern.id == playing)
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
            let length = shown?.length ?? 16
            var added: String?
            player.edit("Add Pattern") { song in
              let result = song.addingPattern(length: length)
              song = result.song
              added = result.id
            }
            // Made in order to be worked on: it is the one shown.
            if let added { player.editing = added }
          } label: {
            Image(systemName: "plus")
          }
          .help("Add a pattern")
          Button {
            if let id = shown?.id { duplicate(id) }
          } label: {
            Image(systemName: "plus.square.on.square")
          }
          .help("Duplicate this pattern")
          Button {
            if let id = shown?.id { remove(id) }
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

    private func chip(_ pattern: DriftboxSeq.Pattern, shown: Bool, playing: Bool) -> some View {
      Button {
        player.editing = pattern.id
      } label: {
        HStack(spacing: 5) {
          if playing {
            Circle().fill(Theme.live).frame(width: 5, height: 5).shadow(color: Theme.live, radius: 3)
          }
          Text(pattern.name).lineLimit(1)
        }
      }
      .buttonStyle(.chip(on: shown, tint: player.editing == nil ? Theme.live : Theme.eight))
      .simultaneousGesture(TapGesture(count: 2).onEnded { startRenaming(pattern) })
      .popover(
        isPresented: Binding(get: { renaming == pattern.id }, set: { if !$0 { renaming = nil } }),
        arrowEdge: .bottom
      ) {
        RenameField(name: $name) {
          player.edit("Rename Pattern") { $0 = $0.renamingPattern(pattern.id, to: name) }
          renaming = nil
        }
      }
      .contextMenu {
        Button("Rename…") { startRenaming(pattern) }
        Button("Duplicate") { duplicate(pattern.id) }
        Button("Add to End of Song") { player.edit("Add to Song") { $0 = $0.appendingToChain(pattern.id) } }
        Divider()
        Button("Clear Pattern") { player.editPattern(pattern.id, "Clear Pattern") { $0.clearingAll() } }
        Button("Remove Pattern") { remove(pattern.id) }
          .disabled(song.patterns.count < 2)
      }
    }

    private func startRenaming(_ pattern: DriftboxSeq.Pattern) {
      name = pattern.name
      renaming = pattern.id
    }

    private func duplicate(_ id: String) {
      var copy: String?
      player.edit("Duplicate Pattern") { song in
        let result = song.duplicatingPattern(id)
        song = result.song
        copy = result.id
      }
      if let copy { player.editing = copy }
    }

    private func remove(_ id: String) {
      player.edit("Remove Pattern") { song in song = song.removingPattern(id) }
      if player.editing == id { player.editing = nil }
    }
  }

  /// Under the lanes: what shapes the pattern rather than what is in it — a voice to add, its
  /// length, and the 909's flam mode with the flam's width.
  struct PatternFooter: View {
    let player: Session
    let song: Song
    let pattern: DriftboxSeq.Pattern

    var body: some View {
      HStack(spacing: 10) {
        AddLaneMenu(player: player, pattern: pattern)
        Rectangle().fill(Theme.edge).frame(width: 1, height: 16)
        DragNumber(
          label: "Steps", value: Double(pattern.length), range: 1...64, perPoint: 0.15,
          format: { "\(Int($0.rounded()))" }
        ) {
          value in
          player.editPattern(pattern.id, "Set Pattern Length") { $0.resizing(to: Int(value.rounded())) }
        }
        if pattern.tracks.keys.contains(where: { $0.hasPrefix("909.") }) {
          Button("flam") { player.flamMode.toggle() }
            .buttonStyle(.chip(on: player.flamMode, tint: Theme.nine, size: 10))
            .help(
              "Clicking a 909 step marks a flam instead of cycling it. Option-click does the same at any time."
            )
          if player.flamMode {
            DragNumber(
              label: "Width", value: (song.kit.flam ?? 0.4) * 100, range: 0...100, perPoint: 0.5,
              format: { "\(Int($0.rounded()))" }
            ) {
              value in
              player.edit("Set Flam Width") { $0.kit.flam = value.rounded() / 100 }
            }
            .transition(.opacity)
          }
        }
        Spacer()
      }
      .padding(.leading, 4)
      .animation(.easeOut(duration: 0.15), value: player.flamMode)
    }
  }

  /// A name, typed and returned. Escape leaves it as it was.
  struct RenameField: View {
    @Binding var name: String
    let commit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
      HStack(spacing: 8) {
        TextField("Name", text: $name)
          .textFieldStyle(.roundedBorder)
          .font(Theme.mono(12))
          .frame(width: 180)
          .focused($focused)
          .onSubmit(commit)
        Button("Rename", action: commit).keyboardShortcut(.defaultAction)
      }
      .padding(10)
      .onAppear { focused = true }
    }
  }

  /// What can be done to one drum lane, as a menu on its name.
  struct LaneMenu: View {
    let player: Session
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
        Divider()
        Button("Copy Lane") { player.copyLane(voiceId) }
        Button("Cut Lane") { player.cutLane(voiceId) }
        Button("Paste Lane") { player.pasteLane(into: voiceId) }
          .disabled(!player.canPasteLane(into: voiceId))
        Divider()
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
    let player: Session
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
        Divider()
        Button("Copy Line") { player.copyLane(voiceId) }
        Button("Cut Line") { player.cutLane(voiceId) }
        Button("Paste Line") { player.pasteLane(into: voiceId) }
          .disabled(!player.canPasteLane(into: voiceId))
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
