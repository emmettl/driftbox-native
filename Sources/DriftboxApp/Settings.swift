#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxHost
  import SwiftUI

  /// What the app remembers between launches. Small on purpose: a setting the app cannot honour
  /// is worse than no setting at all.
  enum Defaults {
    static let visuals = "visuals.run"
    static let listensToMIDI = "midi.listens"
    static let sendsClock = "clock.sends"
    static let clockDestination = "clock.destination"
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
    @AppStorage(Defaults.sendsClock) private var sends = false
    @AppStorage(Defaults.clockDestination) private var destination = ""

    func body(content: Content) -> some View {
      content
        .onChange(of: visuals, initial: true) { _, on in player.showsVisuals = on }
        .onChange(of: listens, initial: true) { _, on in player.listensToMIDI = on }
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
    @AppStorage(Defaults.sendsClock) private var sends = false
    @AppStorage(Defaults.clockDestination) private var destination = ""

    public init(player: Player) {
      self.player = player
    }

    public var body: some View {
      Form {
        Section("MIDI In") {
          Toggle("Play notes and follow clock from MIDI", isOn: $listens)
          // Every source there is, and not a choice among them: the input connects to all of
          // them, which is one switch and not a list of them.
          let sources = player.midiSources
          LabeledContent("Listening to") {
            Text(sources.isEmpty ? "nothing connected" : sources.joined(separator: ", "))
              .foregroundStyle(.secondary)
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
  }
#endif
