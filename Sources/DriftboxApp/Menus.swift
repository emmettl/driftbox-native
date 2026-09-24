#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxRackSession
  import DriftboxSession
  import SwiftUI

  /// The menu bar. Everything the toolbar does is here too, and the menu is the contract: it is
  /// where a Mac user looks to find out what an application can do — and, for undo, to find out
  /// that it can be undone at all. The toolbar's buttons call the same methods and carry no key
  /// equivalents of their own, so nothing is bound twice.
  public struct AppMenus: Commands {
    let player: Session
    let files: SongFiles
    let stage: Stage
    // Both are remembered between launches, so the menu writes the preference and the window
    // mirrors it onto the player, rather than the two of them setting it from opposite ends.
    @AppStorage(Defaults.visuals) private var showsVisuals = true
    @AppStorage(Defaults.sendsClock) private var sendsClock = false
    @AppStorage(Defaults.metronome) private var metronome = false
    @AppStorage(Defaults.countIn) private var countIn = false
    /// The rack, while its window is in front: undo is its, then.
    @FocusedValue(\.rack) private var rack
    @Environment(\.openWindow) private var openWindow

    public init(player: Session, files: SongFiles, stage: Stage) {
      self.player = player
      self.files = files
      self.stage = stage
    }

    public var body: some Commands {
      CommandGroup(replacing: .newItem) {
        Button("New") { files.new() }
          .keyboardShortcut("n")
        Button("Open…") { files.openPanel() }
          .keyboardShortcut("o")
        Menu("Open Recent") {
          ForEach(files.recent, id: \.self) { url in
            Button(url.lastPathComponent) { files.open(url) }
          }
          Divider()
          Button("Clear Menu") { files.clearRecent() }
        }
        .disabled(files.recent.isEmpty)
      }

      // After the save group rather than instead of it: Close and Close All live there, and the
      // order that leaves — New, Open, Open Recent, Close, Save — is the one every Mac app has.
      CommandGroup(after: .saveItem) {
        Button("Save") { files.save() }
          .keyboardShortcut("s")
          .disabled(player.song == nil)
        Button("Save As…") { files.saveAs() }
          .keyboardShortcut("s", modifiers: [.command, .shift])
          .disabled(player.song == nil)
        Divider()
        Button("Export Mix…") { files.exportMix() }
          .keyboardShortcut("e")
          .disabled(player.song == nil)
        Button("Export Stems…") { files.exportStems() }
          .keyboardShortcut("e", modifiers: [.command, .shift])
          .disabled(player.song == nil)
      }

      // The manager is the one the window hands the content; what these show is read back off it,
      // so an edit that named itself says so here.
      CommandGroup(replacing: .undoRedo) {
        if let rack {
          Button(rack.undoTitle) { rack.undo() }
            .keyboardShortcut("z")
            .disabled(!rack.canUndo)
          Button(rack.redoTitle) { rack.redo() }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!rack.canRedo)
        } else {
          Button(player.undoTitle) { player.undo() }
            .keyboardShortcut("z")
            .disabled(!player.canUndo)
          Button(player.redoTitle) { player.redo() }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!player.canRedo)
        }
      }

      CommandGroup(after: .toolbar) {
        // Not ⇧⌘V, which every Mac user knows as Paste and Match Style.
        Toggle("Vibes", isOn: Binding(get: { stage.performing }, set: { stage.performing = $0 }))
          .keyboardShortcut("p", modifiers: [.command, .shift])
          .disabled(player.song == nil)
        Toggle("Visuals Backdrop", isOn: $showsVisuals)
          .keyboardShortcut("v", modifiers: [.command, .control])
        SceneMenu(player: player, stage: stage)
        // Straight to full screen on a named display, which is the thing a projector wants and
        // otherwise takes opening, dragging across and then going full screen by hand.
        Menu("Visuals Full Screen On") {
          ForEach(stage.screens, id: \.self) { name in
            Button(name) { stage.output.show(on: name, fullScreen: true) }
          }
        }
        Divider()
      }

      // A second window is shown from the Window menu, by number, the way Logic opens its mixer
      // with ⌘2 — and closed like any other window. ⌥⌘V was the first choice and the wrong one:
      // it is a paste shortcut in the Finder.
      CommandGroup(before: .windowList) {
        Button("Visuals") { stage.output.show() }
          .keyboardShortcut("2")
        Button("Rack") { openWindow(id: "rack") }
          .keyboardShortcut("3")
        Divider()
      }

      CommandMenu("Transport") {
        // Space plays and stops at the window, where it has always worked; a key equivalent here
        // as well would be the same key bound twice. This is for finding out that it exists.
        Button(player.isPlaying ? "Stop" : "Play") { player.toggle() }
          .disabled(player.song == nil)
        Button("Return to Start") { player.seek(toStep: 0) }
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(player.song == nil)
        Divider()
        Button("Next Pattern") { player.skip(sections: 1) }
          .keyboardShortcut("]", modifiers: .command)
          .disabled(player.song == nil)
        Button("Previous Pattern") { player.skip(sections: -1) }
          .keyboardShortcut("[", modifiers: .command)
          .disabled(player.song == nil)
        Divider()
        Toggle("Metronome", isOn: $metronome)
          .keyboardShortcut("k", modifiers: .command)
        Toggle("Count In", isOn: $countIn)
          .keyboardShortcut("k", modifiers: [.command, .shift])
        Button("Loop Current Section") {
          guard let song = player.song, let bar = player.position?.bar else { return }
          let block = SongStrip.blocks(song).first { bar >= $0.start && bar < $0.start + $0.bars }
          if let block { player.toggleLoop(start: block.start, bars: block.bars) }
        }
        .keyboardShortcut("l", modifiers: .command)
        .disabled(player.song == nil)
        Button("Clear Loop") { player.loop = nil }
          .disabled(player.loop == nil)
        Divider()
        Toggle(
          "Follow MIDI Clock",
          isOn: Binding(get: { player.followsClock }, set: { player.followsClock = $0 }))
        Toggle("Send MIDI Clock", isOn: $sendsClock)
      }
    }
  }
#endif
