import DriftboxDSP
import DriftboxSeq

/// One 303: a port of `driftbox/packages/engine/src/bassline.ts`.
///
/// It is a different shape from a drum voice because it is a different kind of instrument. A
/// drum hit is built for one sound and thrown away; a 303 is one oscillator running continuously
/// through one filter, with notes scheduled onto it. It has to be, because a slide is a glide
/// between two notes on a single oscillator whose envelope never restarted.
///
/// This is the offline form, like `VoiceRenderer`: notes are scheduled, then it is rendered.
public struct Bassline {
  /// Exponential ramps refuse to touch zero. Everything decays to this instead.
  static var silence: Double { 1e-4 }
  /// A fixed VCA envelope. On the hardware the decay knob reaches the filter envelope only, which
  /// is why turning it down makes a line sound clipped rather than merely quieter.
  static var attack: Double { 0.003 }
  static var release: Double { 0.012 }

  public let sampleRate: Double

  var frequency = ParamTimeline(defaultValue: 440)
  var cutoff = ParamTimeline(defaultValue: 800)
  var resonance = ParamTimeline(defaultValue: 0.5)
  var gain = ParamTimeline(defaultValue: 1)
  /// An oscillator's shape is a plain property, not something that can be scheduled: it changes
  /// when the note is *scheduled*, which is a little before the note sounds.
  var waves: [(time: Double, wave: BassWave)] = [(0, .sawtooth)]

  /// What the oscillator was last told, because a slide starts from it.
  var lastFrequency = 110.0
  var lastGain = 0.0
  /// When the last note stops holding. A note that arrives before this is a slide landing on a
  /// note still sounding, and the VCA has to pick up from where it is rather than from silence.
  var heldUntil = 0.0

  public init(sampleRate: Double) {
    self.sampleRate = sampleRate
    frequency.setValue(lastFrequency, at: 0)
    gain.setValue(0, at: 0)
  }

  /// Schedule one note at `time`.
  ///
  /// `scheduledAt` is when the call is being made, on the same clock, and defaults to the note's
  /// own time. It matters because scheduling a note cancels what was scheduled before it, and a
  /// filter sweep still under way is cut short *when the cancellation is made*, not when the new
  /// note sounds; and because a change of waveform cannot be scheduled at all, and takes effect
  /// on the spot. The reference schedules each note from the start of the render quantum it falls
  /// in — up to 127 frames early — so a test holding this to the reference has to say so. Played
  /// from a sequencer that schedules to the sample, the two moments are the same.
  public mutating func play(_ note: BassNote, at time: Double, scheduledAt: Double? = nil) {
    let now = scheduledAt ?? time
    if note.wave != waves[waves.count - 1].wave { waves.append((now, note.wave)) }
    // The last frame rendered before this call: the frame before the first one at or after `now`.
    // Nothing has been, for a call at the very start. Worked out in frames, because a second
    // subtracted from a second is not always on a frame.
    let nowFrame = (now * sampleRate).rounded(.up)
    let lastRendered: Double? = nowFrame > 0 ? (nowFrame - 1) / sampleRate : nil

    frequency.cancel(from: time, lastRendered: lastRendered)
    if note.glide > 0 {
      // Exponential, because a glide that sounds even has to move by ratio.
      frequency.setValue(note.glideFrom ?? lastFrequency, at: time)
      frequency.exponentialRamp(to: note.frequency, at: time + note.glide)
    } else {
      frequency.setValue(note.frequency, at: time)
    }
    lastFrequency = note.frequency

    resonance.cancel(from: time, lastRendered: lastRendered)
    resonance.setValue(note.resonance, at: time)

    if note.retrigger {
      // The filter envelope restarts only on a note that was struck. A slid-in note inherits
      // wherever the sweep had got to, which is why a run of slides gets progressively duller.
      cutoff.cancel(from: time, lastRendered: lastRendered)
      cutoff.setValue(note.filterPeak, at: time)
      cutoff.exponentialRamp(to: note.filterBase, at: time + note.filterDecay)
    }

    gain.cancel(from: time, lastRendered: lastRendered)
    gain.setValue(time < heldUntil ? max(lastGain, Self.silence) : Self.silence, at: time)
    // A struck note gets the fixed attack. A slid-in note's level moves over the same time as its
    // pitch, so an accented note landing mid-slide swells into place rather than stepping.
    gain.linearRamp(to: note.gain, at: time + (note.retrigger ? Self.attack : min(note.glide, note.gate)))
    gain.setValue(note.gain, at: time + note.gate)
    gain.exponentialRamp(to: Self.silence, at: time + note.gate + Self.release)

    lastGain = note.gain
    heldUntil = time + note.gate
  }

  /// Everything scheduled so far, from time zero. Oscillator into the ladder, ladder into the
  /// VCA: filter before amplifier, as on the machine, so the resonant peak rings through the gaps
  /// between notes instead of ducking with the envelope.
  public func render(frames: Int) -> [Float] {
    let sawtooth = WaveTable(shape: .sawtooth, sampleRate: sampleRate)
    let square = WaveTable(shape: .square, sampleRate: sampleRate)
    var ladder = Ladder(sampleRate: sampleRate)
    var out = [Float](repeating: 0, count: frames)

    sawtooth.withReader { sawtooth in
      square.withReader { square in
        var phase = 0.0
        var waveIndex = 0
        for frame in 0..<frames {
          let time = Double(frame) / sampleRate
          while waveIndex + 1 < waves.count, waves[waveIndex + 1].time <= time { waveIndex += 1 }
          let reader = waves[waveIndex].wave == .sawtooth ? sawtooth : square

          // The browser's parameters are single precision, and so is what passes between nodes.
          let hertz = Double(Float(frequency.value(at: time)))
          let oscillator = Float(reader.sample(at: phase, frequency: hertz))
          phase = reader.advance(phase, frequency: hertz)

          let filtered = Float(
            ladder.process(
              Double(oscillator), cutoff: Double(Float(max(20, min(20000, cutoff.value(at: time))))),
              resonance: Double(Float(max(0, min(1, resonance.value(at: time)))))))
          out[frame] = filtered * Float(gain.value(at: time))
        }
      }
    }
    return out
  }
}
