#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxHost
  import DriftboxHostMac
  import DriftboxRackSession
  import DriftboxSession
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
    static let metronome = "transport.metronome"
    static let countIn = "transport.countIn"
    static let clockDestination = "clock.destination"
    static let lastSong = "song.last.catalogue"
    static let lastFile = "song.last.file"
    /// The pattern chosen to edit in that song, if one was rather than following the transport.
    static let lastPattern = "song.last.pattern"
    static let outputOpen = "visuals.window.open"
    static let outputScreen = "visuals.window.screen"
    static let outputFullScreen = "visuals.window.fullScreen"
    /// The device to play through, by its UID; empty for the system's.
    static let audioOutput = "audio.output"
    /// Its name, for saying which device it is while it is not plugged in.
    static let audioOutputName = "audio.output.name"
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
    let player: Session
    @AppStorage(Defaults.visuals) private var visuals = true
    @AppStorage(Defaults.listensToMIDI) private var listens = true
    @AppStorage(Defaults.ignoredMIDI) private var ignored = ""
    @AppStorage(Defaults.sendsClock) private var sends = false
    @AppStorage(Defaults.clockDestination) private var destination = ""
    @AppStorage(Defaults.audioOutput) private var output = ""
    @AppStorage(Defaults.metronome) private var metronome = false
    @AppStorage(Defaults.countIn) private var countIn = false

    func body(content: Content) -> some View {
      content
        .onChange(of: metronome, initial: true) { _, on in player.metronome = on }
        .onChange(of: countIn, initial: true) { _, on in player.countsIn = on }
        .onChange(of: output, initial: true) { _, uid in player.outputDevice = uid.isEmpty ? nil : uid }
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

  /// The settings window: where the sound goes, what the rack listens to, the MIDI the app listens
  /// to, the clock it sends, and whether the visuals run. Everything here is something the engine
  /// actually reads.
  public struct SettingsView: View {
    let player: Session
    /// The rack, whose input is chosen here. It remembers the choice itself, so there is no
    /// preference of the app's to mirror.
    let rack: RackSession
    @AppStorage(Defaults.visuals) private var visuals = true
    @AppStorage(Defaults.listensToMIDI) private var listens = true
    @AppStorage(Defaults.ignoredMIDI) private var ignored = ""
    @AppStorage(Defaults.sendsClock) private var sends = false
    @AppStorage(Defaults.clockDestination) private var destination = ""
    @AppStorage(Defaults.audioOutput) private var output = ""
    @AppStorage(Defaults.audioOutputName) private var outputName = ""

    public init(player: Session, rack: RackSession) {
      self.player = player
      self.rack = rack
    }

    public var body: some View {
      Form {
        Section("Audio Out") {
          Picker("Play through", selection: device) {
            Text(player.systemOutput.map { "System (\($0.name))" } ?? "System").tag("")
            ForEach(player.outputs, id: \.id) { output in Text(output.name).tag(output.id) }
            // A choice that is not plugged in is still the choice, and says so, rather than the
            // picker quietly showing something else.
            if !output.isEmpty, !player.outputs.contains(where: { $0.id == output }) {
              Text("\(outputName.isEmpty ? "A device" : outputName) (not connected)").tag(output)
            }
          }
          if !output.isEmpty, let playing = player.playingThrough, playing.id != output {
            Text("Playing through \(playing.name) until it is back.").foregroundStyle(.secondary)
          }
        }
        if rack.takesInput {
          Section("Audio In") {
            Picker("Listen to", selection: inputDevice) {
              Text(rack.systemInput.map { "System (\($0.name))" } ?? "System").tag("")
              ForEach(rack.inputs, id: \.id) { input in Text(input.name).tag(input.id) }
              if let chosen = rack.inputDevice, !rack.inputs.contains(where: { $0.id == chosen }) {
                Text("\(rack.inputDeviceName ?? "A device") (not connected)").tag(chosen)
              }
            }
            if let error = rack.inputError {
              Text(error).foregroundStyle(.secondary)
            } else if let chosen = rack.inputDevice, let hearing = rack.hearing, hearing.id != chosen {
              Text("Listening to \(hearing.name) until it is back.").foregroundStyle(.secondary)
            } else {
              Text("What the rack's Audio Input modules hear, while a patch has one.")
                .foregroundStyle(.secondary)
            }
          }
        }
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

    /// The device chosen, as a selection that writes its name down with it.
    private var device: Binding<String> {
      Binding(
        get: { output },
        set: { uid in
          if let chosen = player.outputs.first(where: { $0.id == uid }) { outputName = chosen.name }
          if uid.isEmpty { outputName = "" }
          output = uid
        })
    }

    /// The input chosen, as a selection with the system's as the empty string. The rack names it
    /// and writes it down.
    private var inputDevice: Binding<String> {
      Binding(
        get: { rack.inputDevice ?? "" },
        set: { id in rack.inputDevice = id.isEmpty ? nil : id })
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
