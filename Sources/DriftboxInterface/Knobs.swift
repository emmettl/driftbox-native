import DriftboxEngine
import DriftboxSeq
import Foundation

/// What one knob is: what it says, and how it shows its value. The same labels and units as the
/// web's panels and the Mac's, so a knob is called the same thing everywhere.
public struct KnobSpec: Sendable {
  public let label: String
  public var format: @Sendable (Double) -> String = KnobSpec.percent

  public init(label: String, format: @escaping @Sendable (Double) -> String = KnobSpec.percent) {
    self.label = label
    self.format = format
  }

  public static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))" }

  /// Left, centre, right: a pan knob's middle is its rest, not fifty of something.
  public static func bipolar(_ value: Double) -> String {
    let amount = Int(((value - 0.5) * 200).rounded())
    return amount == 0 ? "C" : amount < 0 ? "L\(-amount)" : "R\(amount)"
  }

  /// A drum voice's six, the same on every voice: where decay is is learnt once.
  public static let voice: [KnobSpec] = [
    KnobSpec(label: "Level"), KnobSpec(label: "Tune"), KnobSpec(label: "Decay"),
    KnobSpec(label: "Tone"), KnobSpec(label: "Colour"), KnobSpec(label: "Pan", format: bipolar),
  ]

  public static let sends: [KnobSpec] = [KnobSpec(label: "Delay"), KnobSpec(label: "Reverb")]

  /// A 303's, the ones on the front of the machine.
  public static let bass: [KnobSpec] = [
    KnobSpec(label: "Tune"), KnobSpec(label: "Wave", format: { $0 < 0.5 ? "saw" : "sqr" }),
    KnobSpec(label: "Cutoff"), KnobSpec(label: "Reso"), KnobSpec(label: "Env Mod"),
    KnobSpec(label: "Decay"), KnobSpec(label: "Accent"), KnobSpec(label: "Level"),
  ]

  public static func percentOr(_ zero: String) -> @Sendable (Double) -> String {
    { $0 == 0 ? zero : percent($0) }
  }

  /// The master path, in `FxParams.names` order, each in its own units: a filter in hertz, a delay
  /// in sixteenths because that is what it snaps to, a reverb in seconds.
  public static let fx: [KnobSpec] = [
    KnobSpec(label: "Drive", format: percentOr("clean")),
    KnobSpec(label: "PCF", format: percentOr("off")),
    KnobSpec(label: "Cutoff", format: { "\(Int(MasterInserts.filterFrequency($0).rounded()))Hz" }),
    KnobSpec(label: "Reso"),
    KnobSpec(label: "Env"),
    KnobSpec(
      label: "Decay", format: { "\(Int((MasterInserts.filterDecaySeconds($0) * 1000).rounded()))ms" }),
    KnobSpec(label: "Comp", format: percentOr("off")),
    KnobSpec(label: "Time", format: { "\(delayDivision($0))/16" }),
    KnobSpec(label: "F.back"),
    KnobSpec(label: "Tone"),
    KnobSpec(label: "Size", format: { String(format: "%.1fs", 0.3 + $0 * 3.5) }),
    KnobSpec(label: "Damp"),
  ]

  /// The master path's knobs by what they belong to, as indices into `fx`.
  public static let fxGroups: [(name: String, knobs: [Int])] = [
    ("Insert", [0, 6]), ("Filter", [1, 2, 3, 4, 5]), ("Delay", [7, 8, 9]), ("Reverb", [10, 11]),
  ]
}

/// What a knob turns, in the song.
public enum KnobTarget: Hashable, Sendable {
  /// One of a drum voice's six.
  case voice(String, Int)
  /// One of a 303's eight.
  case bass(String, Int)
  /// A voice's send to the delay or the reverb.
  case send(String, Int)
  /// A voice's swing, as an offset from the song's.
  case swing(String)
  /// One of the song's effects.
  case fx(Int)

  public var spec: KnobSpec {
    switch self {
    case .voice(_, let knob): KnobSpec.voice[knob]
    case .bass(_, let knob): KnobSpec.bass[knob]
    case .send(_, let knob): KnobSpec.sends[knob]
    case .swing: KnobSpec(label: "Swing")
    case .fx(let knob): KnobSpec.fx[knob]
    }
  }

  /// Where it is in `song`.
  public func value(in song: Song) -> Double {
    switch self {
    case .voice(let id, let knob): (song.kit.params[id] ?? VoiceParams())[knob]
    case .bass(let id, let knob): (song.kit.bass[id] ?? BassParams())[knob]
    case .send(let id, let knob): (song.kit.sends[id] ?? SendLevels())[knob]
    case .swing(let id): song.kit.swing[id] ?? 0.5
    case .fx(let knob): song.fx[knob]
    }
  }

  /// Where it started life, which a double-click puts it back to.
  public var rest: Double {
    switch self {
    case .voice(_, let knob): VoiceParams.defaults[knob]
    case .bass(_, let knob): BassParams.defaults[knob]
    case .send(_, let knob): SendLevels.defaults[knob]
    case .swing: 0.5
    case .fx(let knob): FxParams.defaults[knob]
    }
  }

  /// What it says it is at `value` in `song`. A voice's swing says how much the voice swings, with
  /// a dot before it while it swings as the song does.
  public func format(_ value: Double, in song: Song) -> String {
    guard case .swing = self else { return spec.format(value) }
    let effective = Int((max(0, min(1, song.swing + (value - 0.5) * 2)) * 100).rounded())
    return value == 0.5 ? "· \(effective)" : "\(effective)"
  }

  /// What its edit is called, for Undo.
  public var editName: String {
    switch self {
    case .send: "Set \(spec.label) Send"
    case .swing: "Set Voice Swing"
    default: "Set \(spec.label)"
    }
  }

  /// `song` with the knob at `value`.
  public func set(_ value: Double, in song: inout Song) {
    switch self {
    case .voice(let id, let knob):
      var edited = song.kit.params[id] ?? VoiceParams()
      edited[knob] = value
      song.kit.params[id] = edited
    case .bass(let id, let knob):
      var edited = song.kit.bass[id] ?? BassParams()
      edited[knob] = value
      song.kit.bass[id] = edited
    case .send(let id, let knob):
      var edited = song.kit.sends[id] ?? SendLevels()
      edited[knob] = value
      song.kit.sends[id] = edited
    case .swing(let id):
      song.kit.swing[id] = value
    case .fx(let knob):
      song.fx[knob] = value
    }
  }
}
