import DriftboxRackSession
import DriftboxScenes
import DriftboxSession
import DriftboxShell

/// The menu bar as the session now is: data, made afresh every frame and handed to the window only
/// when it differs from what the window has. What changes it is what a menu's items are — the
/// songs, the Edit menu's words, the devices and sources there are — and not whether a setting is
/// on, which the window asks as a menu opens.
///
/// Every command is an id. The ones about something carry it after a prefix: `song.acid`,
/// `scene.frost`, `output.<device>`, `input.<source>`, `clock.<port>`.
public enum DesktopMenus {
  public static let new = "file.new"
  public static let open = "file.open"
  public static let save = "file.save"
  public static let saveAs = "file.saveAs"
  public static let exportMix = "file.exportMix"
  /// A recent song, by its place in the list; the list cleared; and what an empty list says.
  public static let recentPrefix = "recent."
  public static let clearRecent = "file.clearRecent"
  public static let noRecent = "file.noRecent"
  public static let exportStems = "file.exportStems"
  public static let exportMovie = "file.exportMovie"
  public static let stopMovie = "file.stopMovie"
  public static let record = "file.record"
  public static let exit = "file.exit"
  public static let undo = "edit.undo"
  public static let redo = "edit.redo"
  public static let toggle = "transport.toggle"
  public static let start = "transport.start"
  public static let previousSection = "transport.previousSection"
  public static let nextSection = "transport.nextSection"
  public static let loop = "transport.loop"
  public static let clearLoop = "transport.clearLoop"
  public static let metronome = "transport.metronome"
  public static let recordAutomation = "transport.recordAutomation"
  public static let clearAutomation = "transport.clearAutomation"
  public static let countIn = "transport.countIn"
  public static let nextScene = "view.nextScene"
  public static let previousScene = "view.previousScene"
  public static let songsScene = "view.songsScene"
  public static let controls = "view.controls"
  public static let showRack = "rack.show"
  public static let rackBack = "rack.back"
  public static let systemOutput = "audio.system"
  public static let listen = "midi.listen"
  public static let followClock = "midi.followClock"
  public static let sendClock = "midi.sendClock"
  /// What a list with nothing in it shows, which can be neither chosen nor ticked.
  public static let noInputs = "midi.noInputs"
  public static let noOutputs = "midi.noOutputs"
  /// Whether the scene runs behind the controls; it always does while they are away.
  public static let visuals = "view.visuals"
  /// The visuals in a window of their own; and that window full screen on a display, by its name.
  public static let visualsWindow = "view.visualsWindow"
  public static let visualsOnPrefix = "visualsOn."
  /// What the Audio menu says of where the sound is going, which is not a choice.
  public static let audioNote = "audio.note"

  public static let songPrefix = "song."
  public static let scenePrefix = "scene."
  public static let outputPrefix = "output."
  public static let inputPrefix = "input."
  public static let clockPrefix = "clock."
  public static let patchPrefix = "patch."
  /// A catalogue song into the rack, by its id; and the groovebox's own song into it.
  public static let rackSongPrefix = "rackSong."
  public static let rackSongFromGroovebox = "rack.songFromGroovebox"

  /// File ▸ Open Recent: the songs, by the menu's names for them, or word that there are none.
  static func recentMenu(_ titles: [String]) -> Menu {
    guard !titles.isEmpty else { return Menu("Open Recent", [.command("No Recent Songs", id: noRecent)]) }
    let songs: [MenuItem] = titles.enumerated().map {
      .command($0.element, id: recentPrefix + String($0.offset))
    }
    return Menu("Open Recent", songs + [.separator, .command("Clear Menu", id: clearRecent)])
  }

  /// What a command is about, if it is one of `prefix`'s.
  public static func value(_ id: String, after prefix: String) -> String? {
    id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : nil
  }

  /// The menus for `session`, and for `rack` when there is one: the Edit menu undoes in whichever
  /// shows. While a movie is being written, the File menu stops it.
  @MainActor
  public static func bar(
    for session: Session, rack: RackSession? = nil, showsRack: Bool = false, writingMovie: Bool = false,
    displays: [String] = [], visualsWindow: Bool = false, recent: [String]? = nil
  ) -> MenuBar {
    // The songs opened lately, where the app keeps them.
    let recentItems = recent.map { [MenuItem.submenu(recentMenu($0))] } ?? []
    // The visuals in a window of their own, where the platform has a second window, and that window
    // full screen on each display there is.
    let visualsItems: [MenuItem] =
      visualsWindow
      ? [
        .command("Visuals Window", id: DesktopMenus.visualsWindow, shortcut: Shortcut("2")),
        .submenu(Menu("Visuals Full Screen On", displays.map { .command($0, id: visualsOnPrefix + $0) })),
      ] : []
    let undoTitle = showsRack ? rack?.undoTitle ?? "Undo" : session.undoTitle
    let redoTitle = showsRack ? rack?.redoTitle ?? "Redo" : session.redoTitle
    return MenuBar(
      [
        Menu(
          "File",
          [
            .command("New", id: new, shortcut: Shortcut("n")),
            .command("Open…", id: open, shortcut: Shortcut("o")),
          ] + recentItems + [
            .submenu(
              Menu("Open Catalogue Song", session.entries.map { .command($0.name, id: songPrefix + $0.id) })),
            .separator,
            .command("Save", id: save, shortcut: Shortcut("s")),
            .command("Save As…", id: saveAs, shortcut: Shortcut("s", [.primary, .shift])),
            .separator,
            .command("Export Mix…", id: exportMix, shortcut: Shortcut("e")),
            .command("Export Stems…", id: exportStems, shortcut: Shortcut("e", [.primary, .shift])),
            writingMovie
              ? .command("Stop Writing Movie", id: stopMovie, shortcut: Shortcut("m", [.primary, .shift]))
              : .command("Export Movie…", id: exportMovie, shortcut: Shortcut("m", [.primary, .shift])),
            .command(
              session.isRecording ? "Stop Recording…" : "Record Performance", id: record,
              shortcut: Shortcut("r", [.primary, .shift])),
            .separator,
            .command("Exit", id: exit, shortcut: Shortcut("q")),
          ]),
        Menu(
          "Edit",
          [
            .command(undoTitle, id: undo, shortcut: Shortcut("z")),
            .command(redoTitle, id: redo, shortcut: Shortcut("y")),
          ]),
        Menu(
          "Transport",
          [
            .command("Play or Stop", id: toggle, shortcut: Shortcut(.space, [])),
            .command("Return to Start", id: start, shortcut: Shortcut(.home, [])),
            .command("Previous Section", id: previousSection, shortcut: Shortcut(.pageUp, [])),
            .command("Next Section", id: nextSection, shortcut: Shortcut(.pageDown, [])),
            .separator,
            .command("Loop This Section", id: loop, shortcut: Shortcut("l")),
            // Whatever is looping, one section or several stretched across.
            .command("Clear Loop", id: clearLoop, shortcut: Shortcut("l", [.primary, .shift])),
            .command("Metronome", id: metronome, shortcut: Shortcut("m")),
            .separator,
            .command("Record Automation", id: recordAutomation),
            .command("Clear Automation", id: clearAutomation),
            .command("Count In", id: countIn),
          ]),
        Menu(
          "View",
          [
            // Tab turns the rack round while it shows, as it does on the Mac; the controls are the
            // groovebox's.
            showsRack
              ? .command("Show Back", id: rackBack, shortcut: Shortcut(.tab, []))
              : .command("Show Controls", id: controls, shortcut: Shortcut(.tab, [])),
            .separator,
            .command("Run the Visuals", id: visuals),
          ] + visualsItems + [
            .separator,
            .command("Next Scene", id: nextScene, shortcut: Shortcut(.right)),
            .command("Previous Scene", id: previousScene, shortcut: Shortcut(.left)),
            .separator,
            .command("The Song's Scene", id: songsScene),
            .submenu(Menu("Scene", GPUScenes.all.map { .command($0.name, id: scenePrefix + $0.id) })),
          ]),
      ]
        + (rack == nil
          ? []
          : [
            Menu(
              "Rack",
              [
                .command("Show Rack", id: showRack, shortcut: Shortcut("r")),
                .separator,
                .submenu(
                  Menu("Open Patch", PatchEntry.all.map { .command($0.name, id: patchPrefix + $0.id) })),
                // A groovebox song, whole, played beside the rack with its machines on a Groovebox source.
                .submenu(
                  Menu(
                    "Groovebox Songs",
                    (session.song != nil && !session.linkedToRack
                      ? [
                        .command("\(session.documentName), from the Groovebox", id: rackSongFromGroovebox),
                        .separator,
                      ] : [])
                      + session.entries.map { .command($0.name, id: rackSongPrefix + $0.id) })),
              ])
          ])
        + [
          Menu(
            "Audio",
            [.command("System Output", id: systemOutput), .separator]
              + session.outputs.map { .command($0.name, id: outputPrefix + $0.id) } + missingOutput(session)),
          Menu(
            "MIDI",
            [
              .command("Listen to MIDI", id: listen),
              .submenu(
                Menu(
                  "Inputs",
                  session.midiSources.isEmpty
                    ? [.command("No MIDI Inputs", id: noInputs)]
                    : session.midiSources.map { .command($0, id: inputPrefix + $0) })),
              .separator,
              .command("Follow MIDI Clock", id: followClock),
              .command("Send MIDI Clock", id: sendClock),
              .submenu(
                Menu(
                  "Send Clock To",
                  session.clockDestinations.isEmpty
                    ? [.command("No MIDI Outputs", id: noOutputs)]
                    : session.clockDestinations.map { .command($0, id: clockPrefix + $0) })),
            ]),
        ])
  }
}

extension DesktopMenus {
  /// A device chosen and not plugged in is still the choice, and says so, rather than the menu
  /// quietly ticking nothing; with what the sound goes out of until it is back. And why nothing
  /// can be heard, while nothing can.
  @MainActor
  static func missingOutput(_ session: Session) -> [MenuItem] {
    var items: [MenuItem] = []
    if let chosen = session.outputDevice, !session.outputs.contains(where: { $0.id == chosen }) {
      items.append(
        .command("\(session.outputDeviceName ?? "A Device") (Not Connected)", id: outputPrefix + chosen))
      if let playing = session.playingThrough {
        items.append(.command("Playing Through \(playing.name) Until It Is Back", id: audioNote))
      }
    }
    if let error = session.outputError { items.append(.command(error, id: audioNote)) }
    return items.isEmpty ? [] : [.separator] + items
  }
}
