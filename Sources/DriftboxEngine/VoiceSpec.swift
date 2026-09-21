// A drum voice, described as data rather than as code that makes sound. A port of
// `driftbox/packages/engine/src/types.ts`.
//
// This split is the load-bearing idea of the engine, here as there. Every voice is a pure function
// from its knob positions to a `VoiceSpec` — oscillators, noise, envelopes, filters — and one
// renderer turns any spec into samples. So the 22 voices are 22 small functions, checked exactly
// against the reference's, and the sound is one renderer, checked against the browser's.

/// How a value travels to its next breakpoint. Exponential is what almost every drum envelope
/// wants; linear is for a value that must reach or pass through zero.
public enum Curve: Equatable, Sendable {
  case exponential, linear
}

/// Reach `to` at `at` seconds after the hit begins. The starting value is implicit — the source's
/// own frequency or gain — so an envelope is a list of destinations.
public struct Breakpoint: Equatable, Sendable {
  public var to: Double
  public var at: Double
  /// Nil is exponential, as it is in the reference when unstated.
  public var curve: Curve?

  public init(to: Double, at: Double, curve: Curve? = nil) {
    self.to = to
    self.at = at
    self.curve = curve
  }
}

public enum FilterKind: Equatable, Sendable {
  case lowpass, highpass, bandpass
}

public struct FilterSpec: Equatable, Sendable {
  public var type: FilterKind
  public var frequency: Double
  /// Resonance. Decibels for low-pass and high-pass, a plain Q for band-pass. Nil is 1.
  public var q: Double?
  /// A sweep, starting from `frequency`.
  public var envelope: [Breakpoint]?

  public init(type: FilterKind, frequency: Double, q: Double? = nil, envelope: [Breakpoint]? = nil) {
    self.type = type
    self.frequency = frequency
    self.q = q
    self.envelope = envelope
  }
}

public enum Waveform: Hashable, Sendable {
  case sine, triangle, square, sawtooth
}

public struct Oscillator: Equatable, Sendable {
  public var type: Waveform
  public var frequency: Double
  /// Pitch envelope, starting from `frequency`. The drop that makes a kick a kick.
  public var pitch: [Breakpoint]?

  public init(type: Waveform, frequency: Double, pitch: [Breakpoint]? = nil) {
    self.type = type
    self.frequency = frequency
    self.pitch = pitch
  }
}

/// Noise, optionally with the character of a sample ROM: the 909's cymbals came from
/// low-resolution PCM, and giving generated noise that rate and bit depth reproduces the
/// bandwidth and grain without embedding anybody's recording.
public struct Noise: Equatable, Sendable {
  public var sampleRate: Double?
  public var bitDepth: Double?
  /// A seed makes every hit read the same generated waveform, as a ROM would.
  public var seed: Double?
  /// Playback speed: the tune control on a generated PCM voice.
  public var playbackRate: Double?

  public init(
    sampleRate: Double? = nil, bitDepth: Double? = nil, seed: Double? = nil, playbackRate: Double? = nil
  ) {
    self.sampleRate = sampleRate
    self.bitDepth = bitDepth
    self.seed = seed
    self.playbackRate = playbackRate
  }
}

public struct Source: Equatable, Sendable {
  public enum Generator: Equatable, Sendable {
    case oscillator(Oscillator)
    case noise(Noise)
  }

  public var generator: Generator
  /// Peak level of this source, before the voice's own output gain.
  public var gain: Double
  /// Amplitude envelope, starting from silence. The first breakpoint is the attack.
  public var amp: [Breakpoint]
  /// Applied before the voice's filter.
  public var filter: FilterSpec?
  /// Seconds before this source starts — a clap's retriggers are this.
  public var delay: Double?

  public init(
    _ generator: Generator, gain: Double, amp: [Breakpoint], filter: FilterSpec? = nil, delay: Double? = nil
  ) {
    self.generator = generator
    self.gain = gain
    self.amp = amp
    self.filter = filter
    self.delay = delay
  }
}

public struct VoiceSpec: Equatable, Sendable {
  /// How long the whole voice lasts, tail included. A voice that outlives this is cut off.
  public var duration: Double
  public var sources: [Source]
  /// Across the summed sources.
  public var filter: FilterSpec?
  /// Waveshaper amount, 0 for clean. The 909's kick and clap want a little grit.
  public var drive: Double?
  public var gain: Double
  /// -1 hard left to 1 hard right.
  public var pan: Double?
  /// Output normalisation, applied last — after the waveshaper, where it still changes the level.
  public var trim: Double?

  public init(
    duration: Double, sources: [Source], filter: FilterSpec? = nil, drive: Double? = nil, gain: Double,
    pan: Double? = nil, trim: Double? = nil
  ) {
    self.duration = duration
    self.sources = sources
    self.filter = filter
    self.drive = drive
    self.gain = gain
    self.pan = pan
    self.trim = trim
  }
}
