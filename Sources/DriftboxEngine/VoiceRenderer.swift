import DriftboxDSP

/// Turns a `VoiceSpec` into samples: what `renderVoice` and the Web Audio graph behind it do in
/// the reference.
///
/// This is the offline form. It allocates what a hit needs when the hit is built and nothing
/// while it runs, which is the shape the real-time voice pool will need too.
public struct VoiceRenderer {
  /// Web Audio will not ramp exponentially to or from zero, so the reference decays to this.
  static let silence = 1e-4

  /// Why a spec cannot be rendered yet, or nil if it can. The renderer is being built node type
  /// by node type, each measured against the browser before the next, and says so rather than
  /// rendering something close.
  public static func unsupported(_ spec: VoiceSpec) -> String? {
    if let drive = spec.drive, drive > 0 { return "drive (an oversampled waveshaper)" }
    if let pan = spec.pan, pan != 0 { return "pan" }
    for source in spec.sources {
      switch source.generator {
      case .oscillator(let oscillator):
        if oscillator.type != .sine { return "a \(oscillator.type) oscillator (band-limited wavetables)" }
      case .noise(let noise):
        if noise.sampleRate != nil || noise.playbackRate != nil { return "resampled noise" }
      }
    }
    return nil
  }

  /// One hit starting at time zero, mono. Nil if `unsupported`.
  public static func render(_ spec: VoiceSpec, voiceId: String, sampleRate: Double, frames: Int) -> [Float]? {
    guard unsupported(spec) == nil else { return nil }

    var sources = spec.sources.enumerated().map { index, source in
      RenderedSource(source, index: index, voiceId: voiceId, duration: spec.duration, sampleRate: sampleRate)
    }
    var filter = spec.filter.map { RenderedFilter($0, start: 0, sampleRate: sampleRate) }
    let trim = spec.trim ?? 1

    var out = [Float](repeating: 0, count: frames)
    for frame in 0..<frames {
      let time = Double(frame) / sampleRate
      var sum = 0.0
      for index in sources.indices { sum += sources[index].next(time: time) }
      var sample = sum * spec.gain
      if filter != nil { sample = filter!.process(sample, time: time) }
      out[frame] = Float(sample * trim)
    }
    return out
  }
}

/// `applyEnvelope`: an envelope written as destinations becomes ramps on a parameter. A decay to
/// exactly zero is a linear ramp, because an exponential one cannot get there.
func timeline(from start: Double, _ points: [Breakpoint]?, at time: Double, scale: Double = 1)
  -> ParamTimeline
{
  var timeline = ParamTimeline(defaultValue: start)
  var previous = start
  timeline.setValue(previous == 0 ? 0 : max(previous, VoiceRenderer.silence), at: time)
  for point in points ?? [] {
    let to = point.to * scale
    if (point.curve ?? .exponential) == .exponential, previous > 0, to != 0 {
      timeline.exponentialRamp(to: max(to, VoiceRenderer.silence), at: time + point.at)
    } else {
      timeline.linearRamp(to: to, at: time + point.at)
    }
    previous = to
  }
  return timeline
}

struct RenderedFilter {
  var biquad: Biquad
  var frequency: ParamTimeline
  let q: Double
  let swept: Bool

  init(_ spec: FilterSpec, start: Double, sampleRate: Double) {
    let response: Biquad.Response =
      switch spec.type {
      case .lowpass: .lowpass
      case .highpass: .highpass
      case .bandpass: .bandpass
      }
    biquad = Biquad(response: response, sampleRate: sampleRate)
    frequency = timeline(from: spec.frequency, spec.envelope, at: start)
    q = spec.q ?? 1
    swept = spec.envelope?.isEmpty == false
    biquad.set(frequency: frequency.value(at: start), q: q)
  }

  mutating func process(_ input: Double, time: Double) -> Double {
    if swept { biquad.set(frequency: frequency.value(at: time), q: q) }
    return biquad.process(input)
  }
}

struct RenderedSource {
  enum Generator {
    case sine(frequency: ParamTimeline, phase: Double)
    case noise(buffer: NoiseBuffer, position: Double, increment: Double)
  }

  var generator: Generator
  var gain: ParamTimeline
  var filter: RenderedFilter?
  let start: Double
  let stop: Double
  let sampleRate: Double
  var started = false

  init(_ source: Source, index: Int, voiceId: String, duration: Double, sampleRate: Double) {
    let start = source.delay ?? 0
    self.start = start
    stop = duration
    self.sampleRate = sampleRate

    var gain = timeline(from: 0, source.amp, at: start, scale: source.gain)
    gain.setValue(0, at: duration)
    self.gain = gain
    if let spec = source.filter {
      filter = RenderedFilter(spec, start: start, sampleRate: sampleRate)
    }

    switch source.generator {
    case .oscillator(let oscillator):
      generator = .sine(
        frequency: timeline(from: oscillator.frequency, oscillator.pitch, at: start), phase: 0)
    case .noise(let noise):
      let buffer = NoiseBuffer(contextSampleRate: sampleRate, noise: noise)
      let offset = NoiseBuffer.offset(
        voice: voiceId, sourceIndex: index, start: start, seeded: noise.seed != nil)
      generator = .noise(
        buffer: buffer, position: (offset * buffer.sampleRate).rounded(),
        increment: (noise.playbackRate ?? 1) * buffer.sampleRate / sampleRate)
    }
  }

  mutating func next(time: Double) -> Double {
    var sample = 0.0
    if time >= start && time < stop {
      // A source starts when it is told to, not on the next frame: the first frame it sounds on
      // is already a fraction of a frame into it. Measured against the browser on a clap, whose
      // retriggers fall between frames — a renderer that rounds them to a frame is a whole sample
      // out, and two copies of the same noise a sample apart is a comb filter.
      if !started {
        started = true
        let late = (time - start) * sampleRate
        switch generator {
        case .sine(let frequency, let phase):
          generator = .sine(
            frequency: frequency, phase: phase + late * frequency.value(at: start) / sampleRate)
        case .noise(let buffer, let position, let increment):
          generator = .noise(buffer: buffer, position: position + late * increment, increment: increment)
        }
      }

      switch generator {
      case .sine(let frequency, let phase):
        sample = sin2pi(phase)
        generator = .sine(frequency: frequency, phase: phase + frequency.value(at: time) / sampleRate)
      case .noise(let buffer, let position, let increment):
        let count = buffer.samples.count
        let wrapped = position.truncatingRemainder(dividingBy: Double(count))
        let index = Int(wrapped)
        let fraction = wrapped - Double(index)
        let here = Double(buffer.samples[index])
        // Between two samples, a straight line; the buffer loops, so the last sample's neighbour
        // is the first.
        sample = fraction == 0 ? here : here + fraction * (Double(buffer.samples[(index + 1) % count]) - here)
        generator = .noise(buffer: buffer, position: wrapped + increment, increment: increment)
      }
    }
    sample *= gain.value(at: time)
    // The filter runs from the first frame whether or not its source has started, as a node does.
    return filter?.process(sample, time: time) ?? sample
  }
}
