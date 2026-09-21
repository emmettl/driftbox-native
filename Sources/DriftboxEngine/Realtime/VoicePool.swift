import DriftboxDSP
import DriftboxSeq

/// The drum voices, for a render thread: a fixed number of slots, every buffer they will ever
/// need allocated before the first frame, and a `render` that allocates nothing, locks nothing
/// and touches no class.
///
/// It is held to `VoiceRenderer`, the offline form, **to the bit**: the same arithmetic in the
/// same order, so that everything the offline form was shown to do against the browser carries
/// over without being shown again. The offline form is where a voice is understood; this is where
/// it is played.
///
/// Two halves, on two threads. `prepare` turns a hit into a `FixedVoiceSpec` and may allocate; it
/// belongs wherever songs are compiled and knobs are turned. `start` and `render` are the render
/// thread's.
public struct VoicePool: ~Copyable {
  public let sampleRate: Double
  public let capacity: Int

  /// Frames a voice is rendered for after its sources stop: the waveshaper's delay, and room for
  /// a filter to finish ringing. The offline form's figure.
  static var tailFrames: Int { 512 }
  /// Drive is quantised to twentieths, so there are twenty-one curves.
  static var driveCurves: Int { 21 }
  static var driveCurveSamples: Int { 1024 }

  let waves: WaveTable.Bank
  let kernels: UnsafeMutablePointer<Float>
  let curves: UnsafeMutablePointer<Float>
  let shaperState: UnsafeMutablePointer<Float>
  let sources: UnsafeMutablePointer<FixedSource>
  let sourceStates: UnsafeMutablePointer<SourceState>
  let slots: UnsafeMutablePointer<Slot>
  /// Floats of history each slot's waveshaper has to itself.
  let shaperFloats: Int
  /// Sources each slot has room for. A stored copy: a function that promises not to allocate can
  /// only call what makes the same promise, and reading a static across files is a call.
  let perSlot: Int

  /// The noise every hit reads: the ordinary buffer, then the 909's three generated ROMs.
  let noise: UnsafeMutablePointer<Float>
  let noiseCounts: UnsafeMutablePointer<Int>
  let noiseOffsets: UnsafeMutablePointer<Int>
  let noiseSampleRates: UnsafeMutablePointer<Double>
  let noiseKeys: [Noise]

  struct SourceState {
    var phase = 0.0
    var position = 0.0
    var started = false
    var filter = Biquad(response: .lowpass, sampleRate: 1)
  }

  struct Slot {
    var active = false
    var spec = FixedVoiceSpec()
    var filter = Biquad(response: .lowpass, sampleRate: 1)
    var shaper: WaveShaper.Core
  }

  public init(sampleRate: Double, capacity: Int = 32) {
    self.sampleRate = sampleRate
    self.capacity = capacity
    waves = WaveTable.Bank(sampleRate: sampleRate)

    kernels = .allocate(capacity: WaveShaper.Core.kernelFloats)
    WaveShaper.Core.fillKernels(kernels)
    curves = .allocate(capacity: Self.driveCurves * Self.driveCurveSamples)
    for shape in 0..<Self.driveCurves {
      let curve = WaveShaper.driveCurve(amount: Double(shape) / 20)
      for (index, value) in curve.enumerated() { curves[shape * Self.driveCurveSamples + index] = value }
    }
    shaperFloats = WaveShaper.Core.stateFloats
    perSlot = FixedVoiceSpec.maximumSources
    shaperState = .allocate(capacity: capacity * shaperFloats)

    sources = .allocate(capacity: capacity * FixedVoiceSpec.maximumSources)
    sources.initialize(repeating: FixedSource(), count: capacity * FixedVoiceSpec.maximumSources)
    sourceStates = .allocate(capacity: capacity * FixedVoiceSpec.maximumSources)
    sourceStates.initialize(repeating: SourceState(), count: capacity * FixedVoiceSpec.maximumSources)
    slots = .allocate(capacity: capacity)
    for index in 0..<capacity {
      let shaper = WaveShaper.Core(
        curve: curves, curveCount: 0, oversamples: false, kernels: kernels,
        state: shaperState + index * shaperFloats)
      (slots + index).initialize(to: Slot(shaper: shaper))
    }

    // Every kind of noise the kit asks for, generated once. A voice that asked for another kind
    // would read the ordinary buffer.
    var keys = [Noise()]
    for voice in allVoices {
      for source in voice.build(accent: 1).sources {
        if case .noise(var kind) = source.generator {
          kind.playbackRate = nil
          if !keys.contains(kind) { keys.append(kind) }
        }
      }
    }
    noiseKeys = keys
    let buffers = keys.map { NoiseBuffer(contextSampleRate: sampleRate, noise: $0) }
    noise = .allocate(capacity: buffers.reduce(0) { $0 + $1.samples.count })
    noiseCounts = .allocate(capacity: buffers.count)
    noiseOffsets = .allocate(capacity: buffers.count)
    noiseSampleRates = .allocate(capacity: buffers.count)
    var offset = 0
    for (index, buffer) in buffers.enumerated() {
      for (sample, value) in buffer.samples.enumerated() { noise[offset + sample] = value }
      noiseCounts[index] = buffer.samples.count
      noiseOffsets[index] = offset
      noiseSampleRates[index] = buffer.sampleRate
      offset += buffer.samples.count
    }
  }

  deinit {
    kernels.deallocate()
    curves.deallocate()
    shaperState.deallocate()
    sources.deallocate()
    sourceStates.deallocate()
    slots.deallocate()
    noise.deallocate()
    noiseCounts.deallocate()
    noiseOffsets.deallocate()
    noiseSampleRates.deallocate()
  }

  // MARK: - Off the render thread

  /// A hit, made ready to play. `time` is seconds on the clock `render` counts frames of.
  public func prepare(
    _ spec: VoiceSpec, voiceId: String, at time: Double, sends: SendLevels = SendLevels(),
    chokeGroup: UInt8 = 0
  ) -> FixedVoiceSpec {
    var fixed = FixedVoiceSpec()
    fixed.time = time
    fixed.firstFrame = Int((time * sampleRate).rounded(.down))
    fixed.endFrame = fixed.firstFrame + Int((spec.duration * sampleRate).rounded(.up)) + Self.tailFrames
    fixed.endsAt = time + spec.duration
    fixed.chokeGroup = chokeGroup
    fixed.sendDelay = Float(sends.delay)
    fixed.sendReverb = Float(sends.reverb)

    fixed.gain = spec.gain
    if let drive = spec.drive, drive > 0 { fixed.driveCurve = Int(jsRound(drive * 20)) }
    if let filter = spec.filter {
      fixed.hasFilter = true
      fixed.filterResponse = response(filter.type)
      fixed.filterFrequency = fixedTimeline(timeline(from: filter.frequency, filter.envelope, at: time))
      fixed.filterSwept = filter.envelope?.isEmpty == false
      fixed.filterQ = filter.q ?? 1
    }
    if VoiceRenderer.isPanned(spec) {
      let pan = panGains(spec.pan ?? 0)
      fixed.panLeft = pan.left
      fixed.panRight = pan.right
    }
    var trim = ParamTimeline(defaultValue: 1)
    trim.setValue(spec.trim ?? 1, at: time)
    fixed.trim = fixedTimeline(trim)

    fixed.sourceCount = min(spec.sources.count, FixedVoiceSpec.maximumSources)
    for (index, source) in spec.sources.prefix(FixedVoiceSpec.maximumSources).enumerated() {
      var out = FixedSource()
      out.start = time + (source.delay ?? 0)
      out.stop = time + spec.duration
      var gain = timeline(from: 0, source.amp, at: out.start, scale: source.gain)
      gain.setValue(0, at: time + spec.duration)
      out.gain = fixedTimeline(gain)
      if let filter = source.filter {
        out.hasFilter = true
        out.filterResponse = response(filter.type)
        out.filterFrequency = fixedTimeline(timeline(from: filter.frequency, filter.envelope, at: out.start))
        out.filterSwept = filter.envelope?.isEmpty == false
        out.filterQ = filter.q ?? 1
      }
      switch source.generator {
      case .oscillator(let oscillator):
        out.kind = .oscillator
        out.shape =
          switch oscillator.type {
          case .sine: .sine
          case .triangle: .triangle
          case .square: .square
          case .sawtooth: .sawtooth
          }
        out.frequency = fixedTimeline(timeline(from: oscillator.frequency, oscillator.pitch, at: out.start))
      case .noise(let kind):
        out.kind = .noise
        var key = kind
        key.playbackRate = nil
        out.noiseBuffer = noiseKeys.firstIndex(of: key) ?? 0
        let bufferRate = noiseSampleRates[out.noiseBuffer]
        let offset = NoiseBuffer.offset(
          voice: voiceId, sourceIndex: index, start: out.start, seeded: kind.seed != nil)
        out.position = (Double(Float(offset)) * bufferRate).rounded()
        out.increment = Double(Float(kind.playbackRate ?? 1)) * (bufferRate / sampleRate)
      }
      fixed.setSource(out, at: index)
    }
    return fixed
  }

  private func response(_ kind: FilterKind) -> Biquad.Response {
    switch kind {
    case .lowpass: .lowpass
    case .highpass: .highpass
    case .bandpass: .bandpass
    }
  }

  /// Every envelope the kit writes fits in four events. One that did not would be a voice this
  /// pool cannot play, and says so loudly rather than playing it wrong.
  private func fixedTimeline(_ timeline: ParamTimeline) -> FixedTimeline {
    guard let fixed = FixedTimeline(timeline) else {
      preconditionFailure("an envelope with more than four events")
    }
    return fixed
  }

  // MARK: - On the render thread

  /// Start a hit. If every slot is sounding, the one that will finish soonest gives way.
  ///
  /// A hit in a choke group cuts off whatever in that group is still sounding — a closed hat
  /// silencing an open one — over four milliseconds, from a gain of one; see
  /// `VoiceRenderer.renderStereo` for why one.
  @_noAllocation
  public mutating func start(_ spec: FixedVoiceSpec) {
    if spec.chokeGroup != 0 {
      for index in 0..<capacity
      where slots[index].active && slots[index].spec.chokeGroup == spec.chokeGroup
        && slots[index].spec.endsAt > spec.time
      {
        slots[index].spec.trim.append(.set, value: 1, at: spec.time)
        slots[index].spec.trim.append(.linearRamp, value: 0, at: spec.time + 0.004)
      }
    }

    var chosen = 0
    var soonest = Int.max
    for index in 0..<capacity {
      if !slots[index].active {
        chosen = index
        break
      }
      if slots[index].spec.endFrame < soonest {
        soonest = slots[index].spec.endFrame
        chosen = index
      }
    }

    let base = chosen * perSlot
    for index in 0..<spec.sourceCount {
      let source = spec.source(index)
      sources[base + index] = source
      var state = SourceState()
      state.position = source.position
      if source.hasFilter {
        state.filter = Biquad(response: source.filterResponse, sampleRate: sampleRate)
        state.filter.set(frequency: source.filterFrequency.value(at: source.start), q: source.filterQ)
      }
      sourceStates[base + index] = state
    }

    slots[chosen].active = true
    slots[chosen].spec = spec
    if spec.hasFilter {
      slots[chosen].filter = Biquad(response: spec.filterResponse, sampleRate: sampleRate)
      slots[chosen].filter.set(frequency: spec.filterFrequency.value(at: spec.time), q: spec.filterQ)
    }
    let driven = spec.driveCurve >= 0
    slots[chosen].shaper = WaveShaper.Core(
      curve: curves + max(0, spec.driveCurve) * Self.driveCurveSamples,
      curveCount: driven ? Self.driveCurveSamples : 0, oversamples: driven, kernels: kernels,
      state: shaperState + chosen * shaperFloats)
  }

  /// Add `frames` frames of every sounding voice, starting at `firstFrame`, into the bus and into
  /// the two sends.
  @_noAllocation
  public mutating func render(
    firstFrame: Int, frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
    delayLeft: UnsafeMutablePointer<Float>, delayRight: UnsafeMutablePointer<Float>,
    reverbLeft: UnsafeMutablePointer<Float>, reverbRight: UnsafeMutablePointer<Float>
  ) {
    for slot in 0..<capacity where slots[slot].active {
      let base = slot * perSlot
      let count = slots[slot].spec.sourceCount
      let from = max(firstFrame, slots[slot].spec.firstFrame)
      let to = min(firstFrame + frames, slots[slot].spec.endFrame)

      var frame = from
      while frame < to {
        let time = Double(frame) / sampleRate
        var sum = 0.0
        for index in 0..<count { sum += next(base + index, time: time) }

        var sample = sum * slots[slot].spec.gain
        if slots[slot].spec.driveCurve >= 0 { sample = Double(slots[slot].shaper.process(Float(sample))) }
        if slots[slot].spec.hasFilter {
          if slots[slot].spec.filterSwept {
            slots[slot].filter.set(
              frequency: slots[slot].spec.filterFrequency.value(at: time), q: slots[slot].spec.filterQ)
          }
          sample = slots[slot].filter.process(sample)
        }
        let level = slots[slot].spec.trim.value(at: time)
        let outLeft = Float(sample * slots[slot].spec.panLeft * level)
        let outRight = Float(sample * slots[slot].spec.panRight * level)

        let at = frame - firstFrame
        left[at] += outLeft
        right[at] += outRight
        let toDelay = slots[slot].spec.sendDelay
        if toDelay > 0 {
          delayLeft[at] += outLeft * toDelay
          delayRight[at] += outRight * toDelay
        }
        let toReverb = slots[slot].spec.sendReverb
        if toReverb > 0 {
          reverbLeft[at] += outLeft * toReverb
          reverbRight[at] += outRight * toReverb
        }
        frame += 1
      }
      if firstFrame + frames >= slots[slot].spec.endFrame { slots[slot].active = false }
    }
  }

  /// One frame of one source: `RenderedSource.next`, over storage that was there already.
  @_noAllocation
  private func next(_ index: Int, time: Double) -> Double {
    var sample = 0.0
    if time >= sources[index].start && time < sources[index].stop {
      if !sourceStates[index].started {
        sourceStates[index].started = true
        // A buffer starts a fraction of a frame in; an oscillator starts at the top of its cycle.
        if case .noise = sources[index].kind {
          let late = (time - sources[index].start) * sampleRate
          sourceStates[index].position += late * sources[index].increment
        }
      }

      switch sources[index].kind {
      case .oscillator:
        let wave = waves.reader(sources[index].shape)
        let hertz = Double(Float(sources[index].frequency.value(at: time)))
        sample = wave.sample(at: sourceStates[index].phase, frequency: hertz)
        sourceStates[index].phase = wave.advance(sourceStates[index].phase, frequency: hertz)
      case .noise:
        let buffer = noise + noiseOffsets[sources[index].noiseBuffer]
        let count = noiseCounts[sources[index].noiseBuffer]
        let wrapped = wrapPosition(sourceStates[index].position, Double(count))
        let whole = Int(wrapped)
        let fraction = wrapped - Double(whole)
        let here = Double(buffer[whole])
        sample = fraction == 0 ? here : here + fraction * (Double(buffer[(whole + 1) % count]) - here)
        sourceStates[index].position = wrapped + sources[index].increment
      }
    }
    sample *= sources[index].gain.value(at: time)
    guard sources[index].hasFilter else { return sample }
    if sources[index].filterSwept {
      sourceStates[index].filter.set(
        frequency: sources[index].filterFrequency.value(at: time), q: sources[index].filterQ)
    }
    return sourceStates[index].filter.process(sample)
  }
}
