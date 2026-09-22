#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxHost
  import SwiftUI

  /// What the app remembers between launches. Small on purpose: a setting the app cannot honour
  /// is worse than no setting at all.
  enum Defaults {
    static let visuals = "visuals.run"
    static let listensToMIDI = "midi.listens"
    /// The sources not listened to, one name to a line. Stored as what is ignored rather than
    /// what is heard, so a device plugged in for the first time is heard, as every source was
    /// before there was a choice.
    static let ignoredMIDI = "midi.ignored"
    static let sendsClock = "clock.sends"
    static let clockDestination = "clock.destination"
    static let lastSong = "song.last.catalogue"
    static let lastFile = "song.last.file"
    static let outputOpen = "visuals.window.open"
    static let outputScreen = "visuals.window.screen"
    static let outputFullScreen = "visuals.window.fullScreen"
  }

  extension MIDIOutput.Destination {
    /// The destination as something to remember it by. Driftbox's own port has no name, and the
    /// empty string is how it says so.
    var stored: String {
      if case .port(let name) = self { return name }
      return ""
    }

    init(stored: String) {
      self = stored.isEmpty ? .virtual : .port(stored)
    }
  }

  /// The preferences, applied to the player. The defaults are the truth and the player is the
  /// mirror, in one direction only, so that a setting and the thing it controls cannot drift
  /// apart: everything that changes one of these writes the preference and arrives back here.
  struct Preferences: ViewModifier {
    let player: Player
    @AppStorage(Defaults.visuals) private var visuals = true
    @AppStorage(Defaults.listensToMIDI) private var listens = true
    @AppStorage(Defaults.ignoredMIDI) private var ignored = ""
    @AppStorage(Defaults.sendsClock) private var sends = false
    @AppStorage(Defaults.clockDestination) private var destination = ""

    func body(content: Content) -> some View {
      content
        .onChange(of: visuals, initial: true) { _, on in player.showsVisuals = on }
        .onChange(of: listens, initial: true) { _, on in player.listensToMIDI = on }
        .onChange(of: ignored, initial: true) { _, names in
          player.ignoredMIDISources = Set(names.split(separator: "\n").map(String.init))
        }
        .onChange(of: destination, initial: true) { _, name in
          player.clockDestination = MIDIOutput.Destination(stored: name)
        }
        // After the destination, because turning the clock on locates it where it is pointed.
        .onChange(of: sends, initial: true) { _, on in player.sendsClock = on }
    }
  }

  /// The settings window: the MIDI the app listens to, the clock it sends, and whether the
  /// visuals run. Everything here is something the engine actually reads.
  public struct SettingsView: View {
    let player: Player
    @AppStorage(Defaults.visuals) private var visuals = true
    @AppStorage(Defaults.listensToMIDI) private var listens = true
    @AppStorage(Defaults.ignoredMIDI) private var ignored = ""
    @AppStorage(Defaults.sendsClock) private var sends = false
    @AppStorage(Defaults.clockDestination) private var destination = ""

    public init(player: Player) {
      self.player = player
    }

    public var body: some View {
      Form {
        Section("MIDI In") {
          Toggle("Play notes and follow clock from MIDI", isOn: $listens)
          // One switch per source, under the one over all of them. A source that is gone keeps
          // its choice, so plugging it back in does not undo it.
          if player.midiSources.isEmpty {
            Text("Nothing connected").foregroundStyle(.secondary)
          }
          ForEach(player.midiSources, id: \.self) { name in
            Toggle(name, isOn: hearing(name)).disabled(!listens)
          }
        }
        Section("Clock Out") {
          Toggle("Send MIDI clock", isOn: $sends)
          Picker("Destination", selection: $destination) {
            Text("Driftbox Clock").tag("")
            ForEach(player.clockDestinations, id: \.self) { name in Text(name).tag(name) }
          }
        }
        Section("Visuals") {
          Toggle("Run the visuals", isOn: $visuals)
        }
      }
      .formStyle(.grouped)
      .frame(width: 440)
      .fixedSize()
    }

    /// Whether `name` is heard, as a switch that writes the stored list of what is not.
    private func hearing(_ name: String) -> Binding<Bool> {
      Binding(
        get: { !ignored.split(separator: "\n").contains { $0 == name } },
        set: { heard in
          var names = ignored.split(separator: "\n").map(String.init).filter { $0 != name }
          if !heard { names.append(name) }
          ignored = names.sorted().joined(separator: "\n")
        })
    }
  }
#endif
