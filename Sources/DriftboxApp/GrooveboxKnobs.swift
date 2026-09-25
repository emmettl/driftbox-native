#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxEngine
  import DriftboxSeq

  /// A knob of the groovebox's, as something outside it moves it: an app's automation, where the
  /// groovebox plays inside one as an Audio Unit. Where in the song it lives, what the song's
  /// automation calls it, and how the app's face shows it, in the same words and units the
  /// groovebox's own face does.
  public struct GrooveboxKnob: Sendable {
    /// What an app keeps it by: letters, digits and underscores, from the automation target.
    public let identifier: String
    /// What it belongs to: the master path, a 303, a drum voice.
    public let group: String
    public let label: String
    /// The song's automation lane it is, in `AutomationTarget`'s names.
    public let target: String
    /// Where it rests: the value a song that never set it has.
    public let rest: Double
    private let read: @Sendable (Song) -> Double
    private let write: @Sendable (inout Song, Double) -> Void
    private let format: @Sendable (Double) -> String

    init(
      group: String, spec: KnobSpec, target: String, rest: Double, read: @escaping @Sendable (Song) -> Double,
      write: @escaping @Sendable (inout Song, Double) -> Void
    ) {
      self.identifier = String(target.map { $0.isLetter || $0.isNumber ? $0 : "_" })
      self.group = group
      self.label = spec.label
      self.target = target
      self.rest = rest
      self.read = read
      self.write = write
      self.format = spec.format
    }

    /// Where it is in `song`, from 0 to 1.
    public func value(in song: Song) -> Double { read(song) }
    /// `song` with it at `value`, from 0 to 1.
    public func set(_ value: Double, in song: inout Song) { write(&song, min(1, max(0, value))) }
    /// As the face shows it.
    public func display(_ value: Double) -> String { format(value) }

    /// Every one, in an order that only ever grows at the end: an app keeps automation by where a
    /// knob is in it. The song's swing and the master path first, then the two 303s, then every
    /// drum voice of both machines, whether a song uses it or not, so the list is the same for all.
    public static let all: [GrooveboxKnob] = {
      var knobs = [
        GrooveboxKnob(
          group: "Song", spec: KnobSpec(label: "Swing"), target: AutomationTarget.swing, rest: 0,
          read: { $0.swing }, write: { $0.swing = $1 })
      ]
      for (knob, spec) in KnobSpec.fx.enumerated() {
        knobs.append(
          GrooveboxKnob(
            group: "Master", spec: spec, target: AutomationTarget.fx(FxParams.names[knob]),
            rest: FxParams.defaults[knob], read: { $0.fx[knob] }, write: { $0.fx[knob] = $1 }))
      }
      for (id, name) in [("303.a", "303 A"), ("303.b", "303 B")] {
        for (knob, spec) in KnobSpec.bass.enumerated() {
          knobs.append(
            GrooveboxKnob(
              group: name, spec: spec, target: AutomationTarget.bass(id, BassParams.names[knob]),
              rest: BassParams.defaults[knob], read: { ($0.kit.bass[id] ?? .defaults)[knob] },
              write: { song, value in
                var params = song.kit.bass[id] ?? .defaults
                params[knob] = value
                song.kit.bass[id] = params
              }))
        }
        knobs += sends(id, group: name)
      }
      for voice in allVoices {
        let id = voice.id
        let group = "\(voice.machine == .tr909 ? "909" : "808") \(voice.name)"
        for (knob, spec) in KnobSpec.voice.enumerated() {
          knobs.append(
            GrooveboxKnob(
              group: group, spec: spec, target: AutomationTarget.voice(id, VoiceParams.names[knob]),
              rest: VoiceParams.defaults[knob], read: { ($0.kit.params[id] ?? .defaults)[knob] },
              write: { song, value in
                var params = song.kit.params[id] ?? .defaults
                params[knob] = value
                song.kit.params[id] = params
              }))
        }
        knobs += sends(id, group: group)
        knobs.append(
          GrooveboxKnob(
            group: group, spec: KnobSpec(label: "Swing", format: KnobSpec.bipolar),
            target: AutomationTarget.voiceSwing(id), rest: 0.5, read: { $0.kit.swing[id] ?? 0.5 },
            write: { $0.kit.swing[id] = $1 }))
      }
      return knobs
    }()

    private static func sends(_ id: String, group: String) -> [GrooveboxKnob] {
      KnobSpec.sends.enumerated().map { knob, spec in
        GrooveboxKnob(
          group: group, spec: KnobSpec(label: "\(spec.label) Send", format: spec.format),
          target: AutomationTarget.send(id, SendLevels.names[knob]), rest: SendLevels.defaults[knob],
          read: { ($0.kit.sends[id] ?? .defaults)[knob] },
          write: { song, value in
            var levels = song.kit.sends[id] ?? .defaults
            levels[knob] = value
            song.kit.sends[id] = levels
          })
      }
    }
  }
#endif
