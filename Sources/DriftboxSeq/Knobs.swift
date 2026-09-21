/// A bank of knobs, all 0...1, with names.
///
/// The reference treats every such bank the same way — repair it on load, automate it on playback
/// — by walking an object's keys. This is that, without reflection: a fixed list of names and a
/// subscript, so one generic function can do every voice, every synth and the effects.
public protocol KnobSet: Equatable, Sendable {
  /// In the reference's declaration order, which is the order they are written in.
  static var names: [String] { get }
  static var defaults: Self { get }
  subscript(knob: Int) -> Double { get set }
}

/// The knobs a drum voice exposes. Each voice maps them onto its own real ranges.
public struct VoiceParams: KnobSet {
  public var level = 0.8
  public var tune = 0.5
  public var decay = 0.5
  public var tone = 0.5
  /// Extra per-voice character: snappy on a snare, drive on a kick.
  public var colour = 0.5
  public var pan = 0.5

  public init() {}

  public static let names = ["level", "tune", "decay", "tone", "colour", "pan"]
  public static let defaults = VoiceParams()

  public subscript(knob: Int) -> Double {
    get {
      switch knob {
      case 0: level
      case 1: tune
      case 2: decay
      case 3: tone
      case 4: colour
      default: pan
      }
    }
    set {
      switch knob {
      case 0: level = newValue
      case 1: tune = newValue
      case 2: decay = newValue
      case 3: tone = newValue
      case 4: colour = newValue
      default: pan = newValue
      }
    }
  }
}

/// A 303's panel.
public struct BassParams: KnobSet {
  /// Root pitch, two octaves centred on A1.
  public var tune = 0.5
  /// Under 0.5 is the sawtooth, over it the square.
  public var wave = 0.0
  public var cutoff = 0.32
  /// 1 is past the point of self-oscillation.
  public var resonance = 0.72
  public var envMod = 0.6
  /// Filter envelope decay. It does not touch the amplitude envelope, as on the real machine.
  public var decay = 0.42
  public var accent = 0.6
  public var level = 0.7

  public init() {}

  public static let names = ["tune", "wave", "cutoff", "resonance", "envMod", "decay", "accent", "level"]
  public static let defaults = BassParams()

  public subscript(knob: Int) -> Double {
    get {
      switch knob {
      case 0: tune
      case 1: wave
      case 2: cutoff
      case 3: resonance
      case 4: envMod
      case 5: decay
      case 6: accent
      default: level
      }
    }
    set {
      switch knob {
      case 0: tune = newValue
      case 1: wave = newValue
      case 2: cutoff = newValue
      case 3: resonance = newValue
      case 4: envMod = newValue
      case 5: decay = newValue
      case 6: accent = newValue
      default: level = newValue
      }
    }
  }
}

/// How much of one voice goes to each send effect.
public struct SendLevels: KnobSet {
  public var delay = 0.0
  public var reverb = 0.0

  public init() {}

  public static let names = ["delay", "reverb"]
  public static let defaults = SendLevels()

  public subscript(knob: Int) -> Double {
    get { knob == 0 ? delay : reverb }
    set {
      if knob == 0 { delay = newValue } else { reverb = newValue }
    }
  }
}

/// Song-wide master inserts and send effects. The defaults are the mix Driftbox shipped before
/// the inserts were authored: clean drive, the filter bypassed, the original compressor.
public struct FxParams: KnobSet {
  public var drive = 0.0
  public var pcfAmount = 0.0
  public var pcfCutoff = 0.35
  public var pcfResonance = 0.3
  public var pcfEnv = 0.65
  public var pcfDecay = 0.3
  public var compressor = 0.5
  /// Snapped to musical divisions by the engine. 0.25 is the dotted eighth.
  public var delayTime = 0.25
  public var delayFeedback = 0.42
  public var delayTone = 0.5
  public var reverbSize = 0.45
  public var reverbDamping = 0.55

  public init() {}

  public static let names = [
    "drive", "pcfAmount", "pcfCutoff", "pcfResonance", "pcfEnv", "pcfDecay", "compressor",
    "delayTime", "delayFeedback", "delayTone", "reverbSize", "reverbDamping",
  ]
  public static let defaults = FxParams()

  public subscript(knob: Int) -> Double {
    get {
      switch knob {
      case 0: drive
      case 1: pcfAmount
      case 2: pcfCutoff
      case 3: pcfResonance
      case 4: pcfEnv
      case 5: pcfDecay
      case 6: compressor
      case 7: delayTime
      case 8: delayFeedback
      case 9: delayTone
      case 10: reverbSize
      default: reverbDamping
      }
    }
    set {
      switch knob {
      case 0: drive = newValue
      case 1: pcfAmount = newValue
      case 2: pcfCutoff = newValue
      case 3: pcfResonance = newValue
      case 4: pcfEnv = newValue
      case 5: pcfDecay = newValue
      case 6: compressor = newValue
      case 7: delayTime = newValue
      case 8: delayFeedback = newValue
      case 9: delayTone = newValue
      case 10: reverbSize = newValue
      default: reverbDamping = newValue
      }
    }
  }
}
