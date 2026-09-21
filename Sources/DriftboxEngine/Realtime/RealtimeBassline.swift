import DriftboxDSP
import DriftboxSeq

/// One 303 for a render thread: `Bassline` with fixed storage, notes arriving as they are due.
///
/// Held to the offline form to the bit, for notes scheduled at their own time — which is the only
/// way a sequencer inside the render call schedules them. (The offline form can also schedule a
/// note early, as the browser's mix does, and that is where its `scheduledAt` goes.)
public struct RealtimeBassline: ~Copyable {
  public let sampleRate: Double
  let waves: WaveTable.Bank
  var ladder: Ladder
  var phase = 0.0
  var wave = BassWave.sawtooth

  var frequency: FixedTimeline
  var cutoff = FixedTimeline(defaultValue: 800)
  var resonance = FixedTimeline(defaultValue: 0.5)
  var gain: FixedTimeline
  var lastFrequency = 110.0
  var lastGain = 0.0
  var heldUntil = 0.0

  // Copies of the offline form's constants: a static across files is a call the render path may not make.
  let silence = Bassline.silence
  let attack = Bassline.attack
  let release = Bassline.release

  public var sendDelay: Float = 0
  public var sendReverb: Float = 0

  public init(sampleRate: Double) {
    self.sampleRate = sampleRate
    waves = WaveTable.Bank(sampleRate: sampleRate)
    ladder = Ladder(sampleRate: sampleRate)
    frequency = FixedTimeline(defaultValue: 440)
    frequency.append(.set, value: lastFrequency, at: 0)
    gain = FixedTimeline(defaultValue: 1)
    gain.append(.set, value: 0, at: 0)
  }

  /// Schedule one note at `time`, now: the render thread is at the first frame at or after it.
  /// Everything scheduled before that is over, so each parameter starts again from this note.
  @_noAllocation
  public mutating func play(_ note: BassNote, at time: Double) {
    wave = note.wave

    frequency.removeAll()
    if note.glide > 0 {
      frequency.append(.set, value: note.glideFrom ?? lastFrequency, at: time)
      frequency.append(.exponentialRamp, value: note.frequency, at: time + note.glide)
    } else {
      frequency.append(.set, value: note.frequency, at: time)
    }
    lastFrequency = note.frequency

    resonance.removeAll()
    resonance.append(.set, value: note.resonance, at: time)

    if note.retrigger {
      // A slid-in note inherits wherever the sweep had got to: its timeline stays as it was.
      cutoff.removeAll()
      cutoff.append(.set, value: note.filterPeak, at: time)
      cutoff.append(.exponentialRamp, value: note.filterBase, at: time + note.filterDecay)
    }

    gain.removeAll()
    gain.append(.set, value: time < heldUntil ? max(lastGain, silence) : silence, at: time)
    gain.append(
      .linearRamp, value: note.gain, at: time + (note.retrigger ? attack : min(note.glide, note.gate)))
    gain.append(.set, value: note.gain, at: time + note.gate)
    gain.append(.exponentialRamp, value: silence, at: time + note.gate + release)

    lastGain = note.gain
    heldUntil = time + note.gate
  }

  /// One frame at `time`.
  @_noAllocation
  public mutating func next(time: Double) -> Float {
    let reader: WaveTable.Reader
    switch wave {
    case .sawtooth: reader = waves.reader(.sawtooth)
    case .square: reader = waves.reader(.square)
    }
    let hertz = Double(Float(frequency.value(at: time)))
    let oscillator = Float(reader.sample(at: phase, frequency: hertz))
    phase = reader.advance(phase, frequency: hertz)
    let filtered = Float(
      ladder.process(
        Double(oscillator), cutoff: Double(Float(max(20, min(20000, cutoff.value(at: time))))),
        resonance: Double(Float(max(0, min(1, resonance.value(at: time)))))))
    return filtered * Float(gain.value(at: time))
  }
}
