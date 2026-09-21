import DriftboxDSP

/// Turns a `VoiceSpec` into samples: what `renderVoice` and the Web Audio graph behind it do in
/// the reference.
///
/// This is the offline form. It allocates what a hit needs when the hit is built and nothing
/// while it runs, which is the shape the real-time voice pool will need too.
public struct VoiceRenderer {
  /// Web Audio will not ramp exponentially to or from zero, so the reference decays to this.
  static let silence = 1e-4

  public let sampleRate: Double
  /// Built the first time a shape is asked for, and kept: a bank of wavetables is a few dozen
  /// Fourier transforms, which is nothing once and too much per hit.
  private var waves: [Waveform: WaveTable] = [:]

  public init(sampleRate: Double) {
    self.sampleRate = sampleRate
  }

  /// A hit in stereo, as it leaves the voice.
  public struct Stereo: Sendable {
    public var left: [Float]
    public var right: [Float]
  }

  /// One hit starting at time zero, as a mono context would hear it: a panned voice mixed back
  /// down, which is half the sum of its two sides.
  public mutating func render(_ spec: VoiceSpec, voiceId: String, frames: Int) -> [Float] {
    let stereo = renderStereo(spec, voiceId: voiceId, frames: frames)
    guard Self.isPanned(spec) else { return stereo.left }
    return zip(stereo.left, stereo.right).map { 0.5 * ($0 + $1) }
  }

  /// The reference builds a panner only when the pan is not exactly centre. A voice at centre is
  /// therefore the same signal on both sides at full level, where a panner at centre would have
  /// put it 3dB down on each — so a voice gets quieter the moment its pan knob leaves the middle.
  /// That is how the songs were mixed, so it is kept.
  static func isPanned(_ spec: VoiceSpec) -> Bool {
    if let pan = spec.pan, pan != 0 { true } else { false }
  }

  /// One hit starting at time zero.
  public mutating func renderStereo(_ spec: VoiceSpec, voiceId: String, frames: Int) -> Stereo {
    let sampleRate = sampleRate

    var sources = spec.sources.enumerated().map { index, source in
      RenderedSource(source, index: index, voiceId: voiceId, duration: spec.duration, sampleRate: sampleRate)
    }
    var filter = spec.filter.map { RenderedFilter($0, start: 0, sampleRate: sampleRate) }
    let trim = spec.trim ?? 1
    // Drive, then the voice's filter, then pan, then trim: the reference's order.
    let driven = (spec.drive ?? 0) > 0
    var shaper = WaveShaper(
      curve: driven ? WaveShaper.driveCurve(amount: spec.drive ?? 0) : [], oversamples: driven)
    let pan = Self.isPanned(spec) ? panGains(spec.pan ?? 0) : (left: 1.0, right: 1.0)

    // One table per oscillator, in source order, lent for the length of the render.
    let tables = spec.sources.compactMap { source -> WaveTable? in
      guard case .oscillator(let oscillator) = source.generator else { return nil }
      if waves[oscillator.type] == nil {
        let shape: WaveTable.Shape =
          switch oscillator.type {
          case .sine: .sine
          case .triangle: .triangle
          case .square: .square
          case .sawtooth: .sawtooth
          }
        waves[oscillator.type] = WaveTable(shape: shape, sampleRate: sampleRate)
      }
      return waves[oscillator.type]
    }

    return Self.borrowing(tables[...], []) { readers in
      var left = [Float](repeating: 0, count: frames)
      var right = [Float](repeating: 0, count: frames)
      for frame in 0..<frames {
        let time = Double(frame) / sampleRate
        var sum = 0.0
        var reader = 0
        for index in sources.indices {
          if sources[index].isOscillator {
            sum += sources[index].next(time: time, wave: readers[reader])
            reader += 1
          } else {
            sum += sources[index].next(time: time, wave: nil)
          }
        }
        var sample = sum * spec.gain
        if driven { sample = Double(shaper.process(Float(sample))) }
        if filter != nil { sample = filter!.process(sample, time: time) }
        left[frame] = Float(sample * pan.left * trim)
        right[frame] = Float(sample * pan.right * trim)
      }
      return Stereo(left: left, right: right)
    }
  }

  /// Borrows every table at once, which has to be done from the inside out.
  private static func borrowing<Result>(
    _ tables: ArraySlice<WaveTable>, _ readers: [WaveTable.Reader], _ body: ([WaveTable.Reader]) -> Result
  ) -> Result {
    guard let first = tables.first else { return body(readers) }
    return first.withReader { borrowing(tables.dropFirst(), readers + [$0], body) }
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
    /// `phase` is a position in the wavetable, not an angle.
    case oscillator(frequency: ParamTimeline, phase: Double)
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
      generator = .oscillator(
        frequency: timeline(from: oscillator.frequency, oscillator.pitch, at: start), phase: 0)
    case .noise(let noise):
      let buffer = NoiseBuffer(contextSampleRate: sampleRate, noise: noise)
      let offset = NoiseBuffer.offset(
        voice: voiceId, sourceIndex: index, start: start, seeded: noise.seed != nil)
      generator = .noise(
        buffer: buffer, position: (offset * buffer.sampleRate).rounded(),
        // The rate is a parameter, and the browser's parameters are single precision. Over a
        // two-second crash that rounding moves the read position by a few thousandths of a sample,
        // which through noise is the difference between -60dB and -130dB of agreement.
        increment: Double(Float(noise.playbackRate ?? 1)) * (buffer.sampleRate / sampleRate))
    }
  }

  var isOscillator: Bool {
    if case .oscillator = generator { true } else { false }
  }

  mutating func next(time: Double, wave: WaveTable.Reader?) -> Double {
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
        case .oscillator(let frequency, var phase):
          // `advance` moves one frame's worth at a frequency, so a fraction of the frequency is
          // a fraction of a frame.
          if let wave { phase = wave.advance(phase, frequency: late * frequency.value(at: start)) }
          generator = .oscillator(frequency: frequency, phase: phase)
        case .noise(let buffer, let position, let increment):
          generator = .noise(buffer: buffer, position: position + late * increment, increment: increment)
        }
      }

      switch generator {
      case .oscillator(let frequency, let phase):
        guard let wave else { break }
        let hertz = Double(Float(frequency.value(at: time)))
        sample = wave.sample(at: phase, frequency: hertz)
        generator = .oscillator(frequency: frequency, phase: wave.advance(phase, frequency: hertz))
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
