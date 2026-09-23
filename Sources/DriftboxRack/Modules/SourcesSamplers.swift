import DriftboxDSP

// The modules that play recordings: the slicing sampler, the multisample instrument and the audio
// track. Ports of `modules/sampler.ts`, `multisampler.ts` and `audio-track.ts`.
//
// Each reads its audio through a data slot. The reference keeps the array itself and compares it by
// identity; here a slot's `revision` stands in for the identity, and the pointer stays valid after
// the host replaces a slot, because the graph keeps every buffer it was given until it goes.

/// A recording as a module holds it: nil where the reference has `undefined`.
struct Recording {
  var samples: UnsafePointer<Float>?
  var count: Int

  static var none: Recording {
    @_noAllocation get { Recording(samples: nil, count: 0) }
  }

  @_noAllocation
  init(samples: UnsafePointer<Float>?, count: Int) {
    self.samples = samples
    self.count = count
  }

  @_noAllocation
  init(_ buffer: DataBuffer) {
    samples = buffer.samples
    count = buffer.samples == nil ? 0 : buffer.count
  }

  /// `array[index]`: nil where JavaScript reads `undefined` — no array, a negative or fractional
  /// index, or one past the end.
  @_noAllocation
  func at(_ index: Double) -> Double? {
    guard let samples, index >= 0, index < Double(count), index == jsFloor(index) else { return nil }
    return Double(samples[Int(index)])
  }
}

/// Plays one break, sliced into equal parts, a slice per trigger.
public struct Sampler {
  let trigSamples: Int
  /// The revision of the sample last seen: the reference's identity comparison.
  var revision = 0
  var sample = Recording.none
  var length = 0
  var position = -1.0
  var from = 0.0
  var to = 0.0
  var backwards = false
  var lastTrig = 0
  var trigLeft = 0
  var lastRatio = 1.0
  var lastOctaves = Double.nan

  init(sampleRate: Double) {
    trigSamples = Int(max(1, jsCeil(sampleRate * 0.001)))
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let trigIn = inlets[0]
    let sliceCv = inlets[1]
    let pitchCv = inlets[2]
    let out = outlets[0]
    let eoc = outlets[1]
    let sliceCount = params[0]
    let sliceParam = params[1]
    let startParam = params[2]
    let loopParam = params[3]
    let reverseParam = params[4]

    let buffer = context.data[0]
    if buffer.revision != revision {
      revision = buffer.revision
      sample = Recording(buffer)
      length = sample.count
      position = -1
    }

    if sample.samples == nil || length < 2 {
      for i in 0..<frames {
        out[i] = 0
        eoc[i] = 0
      }
      return
    }

    for i in 0..<frames {
      let slices = max(1, min(32, jsRound(Double(sliceCount[i]))))
      let perSlice = Double(length) / slices

      let gate = trigIn[i] >= 0.5 ? 1 : 0
      if gate == 1 && lastTrig == 0 {
        let cv = Double(sliceCv[i]) * slices
        var index = jsRound(Double(sliceParam[i]) + cv)
        index = (index.truncatingRemainder(dividingBy: slices) + slices).truncatingRemainder(
          dividingBy: slices)
        from = index * perSlice
        to = min(Double(length), (index + 1) * perSlice)

        backwards = jsRound(Double(reverseParam[i])) == 1
        let offset = max(0, min(1, Double(startParam[i]))) * (to - from)
        position = backwards ? to - 1 - offset : from + offset
      }
      lastTrig = gate

      if position < 0 {
        out[i] = 0
        eoc[i] = trigLeft > 0 ? 1 : 0
        trigLeft -= 1
        continue
      }

      let octaves = Double(pitchCv[i])
      if octaves != lastOctaves {
        lastOctaves = octaves
        lastRatio = octaves == 0 ? 1 : exp2(octaves)
      }

      let index = jsFloor(position)
      let fraction = position - index
      let a = sample.at(index) ?? 0
      let b = sample.at(index + 1 < Double(length) ? index + 1 : index) ?? 0
      out[i] = Float(a + (b - a) * fraction)

      position += backwards ? -lastRatio : lastRatio

      let done = backwards ? position <= from : position >= to
      if done {
        trigLeft = trigSamples
        if jsRound(Double(loopParam[i])) == 1 {
          position = backwards ? to - 1 : from
        } else {
          position = -1
        }
      }
      if trigLeft > 0 {
        trigLeft -= 1
        eoc[i] = 1
      } else {
        eoc[i] = 0
      }
    }
  }
}

/// A keyed, velocity-layered sampled instrument: a zone chosen on the gate's edge and kept for the
/// note.
public struct Multisampler {
  /// The reference's zone slots are `sample0`, `sample1`, … without end; a def names its slots, so
  /// this has one per MIDI note, and a zone past them plays nothing.
  static var sampleSlots: Int { @_noAllocation get { 128 } }

  let sampleRate: Double
  var position = -1.0
  var sample = Recording.none
  var root = 60.0
  var sourceRate: Double
  var loopStart = 0.0
  var loopEnd = 0.0
  var loops = false
  var velocity = 1.0
  var envelope = 0.0
  var lastGate = 0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate > 0 ? sampleRate : 44100
    sourceRate = self.sampleRate
  }

  @_noAllocation
  func coefficient(_ seconds: Double) -> Double {
    if !(seconds > 0) { return 1 }
    return 1 - expDSP(-4.605170185988091 / max(1, seconds * sampleRate))
  }

  /// `zones[at + offset]` where there are zones and it is finite, which is when the reference uses it.
  @_noAllocation
  static func field(_ zones: UnsafePointer<Float>?, _ at: Int, _ offset: Int) -> Double? {
    guard let zones else { return nil }
    let value = Double(zones[at + offset])
    return value.isFinite ? value : nil
  }

  /// `data.get('sample<index>')`.
  @_noAllocation
  static func slot(_ data: DataSlots, _ index: Int) -> DataBuffer {
    guard index >= 0, index < sampleSlots else { return DataBuffer(samples: nil, count: 0, revision: 0) }
    return data[1 + index]
  }

  @_noAllocation
  mutating func trigger(note: Double, velocity: Double, data: DataSlots) {
    let zoneBuffer = data[0]
    let zones = zoneBuffer.samples
    var chosen = -1
    var best = Double.infinity

    if let zones {
      let count = zoneBuffer.count / 9
      for zone in 0..<count {
        let at = zone * 9
        let root = Double(zones[at]).isFinite ? Double(zones[at]) : 60
        var low = Double(zones[at + 1]).isFinite ? Double(zones[at + 1]) : 0
        var high = Double(zones[at + 2]).isFinite ? Double(zones[at + 2]) : 127
        if low > high {
          let swap = low
          low = high
          high = swap
        }
        var velocityLow = Double(zones[at + 3]).isFinite ? Double(zones[at + 3]) : 0
        var velocityHigh = Double(zones[at + 4]).isFinite ? Double(zones[at + 4]) : 1
        if velocityLow > velocityHigh {
          let swap = velocityLow
          velocityLow = velocityHigh
          velocityHigh = swap
        }
        if note < low || note > high || velocity < velocityLow || velocity > velocityHigh { continue }
        let score = abs(note - root) + abs(velocity - (velocityLow + velocityHigh) * 0.5) * 0.001
        if score < best {
          best = score
          chosen = zone
        }
      }
    } else if Self.slot(data, 0).samples != nil {
      chosen = 0
    }

    let found = chosen >= 0 ? Recording(Self.slot(data, chosen)) : Recording.none
    if found.samples == nil || found.count < 2 {
      sample = .none
      position = -1
      envelope = 0
      return
    }

    let at = chosen * 9
    let root = Self.field(zones, at, 0) ?? 60
    let sourceRate = Self.field(zones, at, 8) ?? sampleRate
    var loopStart = Self.field(zones, at, 5) ?? 0
    var loopEnd = Self.field(zones, at, 6) ?? 1
    let length = Double(found.count)
    loopStart = jsRound(max(0, min(1, loopStart)) * length)
    loopEnd = jsRound(max(0, min(1, loopEnd)) * length)

    sample = found
    position = 0
    self.root = root
    self.sourceRate = sourceRate > 0 ? sourceRate : sampleRate
    self.loopStart = loopStart
    self.loopEnd = max(loopStart + 1, loopEnd)
    if let zones {
      loops = Double(zones[at + 7]) >= 0.5 && self.loopEnd <= length
    } else {
      loops = false
    }
    self.velocity = velocity
    envelope = 0
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let pitch = inlets[0]
    let gateIn = inlets[1]
    let velocityIn = inlets[2]
    let out = outlets[0]
    let envOut = outlets[1]
    let tune = params[0]
    let attack = params[1]
    let release = params[2]
    let velocityAmount = params[3]
    let level = params[4]

    for i in 0..<frames {
      let gate = gateIn[i] >= 0.5 ? 1 : 0
      if gate == 1 && lastGate == 0 {
        let note = 36 + Double(pitch[i]) * 12 + Double(tune[i])
        let raw = Double(velocityIn[i])
        let velocity = raw > 0 ? max(0, min(1, raw)) : 1
        trigger(note: note, velocity: velocity, data: context.data)
      }
      lastGate = gate

      if sample.samples == nil || position < 0 {
        out[i] = 0
        envOut[i] = 0
        continue
      }

      let envelopeTarget: Double = gate == 1 ? 1 : 0
      let seconds = gate == 1 ? Double(attack[i]) : Double(release[i])
      envelope += (envelopeTarget - envelope) * coefficient(seconds)

      let index = jsFloor(position)
      let fraction = position - index
      let a = sample.at(index) ?? 0
      let b = sample.at(index + 1 < Double(sample.count) ? index + 1 : index) ?? 0
      let played = a + (b - a) * fraction
      let amount = Double(velocityAmount[i])
      let velocityGain = 1 - amount + amount * velocity
      out[i] = Float(played * envelope * velocityGain * Double(level[i]))
      envOut[i] = Float(envelope)

      let note = 36 + Double(pitch[i]) * 12 + Double(tune[i])
      var ratio = (sourceRate / sampleRate) * exp2((note - root) / 12)
      if !ratio.isFinite || ratio <= 0 { ratio = 1 }
      position += ratio

      if gate == 1 && loops && position >= loopEnd {
        let length = loopEnd - loopStart
        position = loopStart + (position - loopStart).truncatingRemainder(dividingBy: length)
      } else if position >= Double(sample.count) || (gate == 0 && envelope < 1e-5) {
        position = -1
        sample = .none
        envelope = 0
      }
    }
  }
}

/// One stereo recording placed on the transport, played once from its start.
public struct AudioTrack {
  let sampleRate: Double
  var left = Recording.none
  var right = Recording.none
  var rateData = Recording.none
  /// The revisions of the three slots as last seen: the reference's identity comparisons.
  var leftRevision = 0
  var rightRevision = 0
  var rateRevision = 0
  var sourceRate: Double
  var position = -1.0
  var running = false
  var lastBeat = 0.0
  var start = -1.0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate > 0 ? sampleRate : 44100
    sourceRate = self.sampleRate
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let transport = context.transport
    let nextLeft = context.data[0]
    let nextRight = context.data[1]
    let nextRateData = context.data[2]
    let start = max(0, jsRound(Double(params[0][0])))
    let changed =
      nextLeft.revision != leftRevision || nextRight.revision != rightRevision
      || nextRateData.revision != rateRevision || start != self.start
    if changed {
      leftRevision = nextLeft.revision
      rightRevision = nextRight.revision
      rateRevision = nextRateData.revision
      left = Recording(nextLeft)
      right = Recording(nextRight)
      rateData = Recording(nextRateData)
      if let sourceRate = rateData.at(0), sourceRate > 0 {
        self.sourceRate = sourceRate
      } else {
        self.sourceRate = sampleRate
      }
      self.start = start
      position = -1
    }

    let outLeft = outlets[0]
    let outRight = outlets[1]
    if !transport.running {
      for i in 0..<frames {
        outLeft[i] = 0
        outRight[i] = 0
      }
      running = false
      position = -1
      lastBeat = transport.beat
      return
    }

    let rewound = transport.beat + 1e-7 < lastBeat
    if !running || rewound { position = -1 }
    running = true
    let beatPerFrame = frames > 0 ? transport.beatsPerBlock / Double(frames) : 0
    let startBeat = start / 4
    if position < 0 && changed && transport.beat > startBeat && beatPerFrame > 0 {
      position = max(0, ((transport.beat - startBeat) / beatPerFrame) * (sourceRate / sampleRate))
    }

    let level = params[1]
    for frame in 0..<frames {
      let beat = transport.beat + beatPerFrame * Double(frame)
      if position < 0 && beat >= startBeat { position = 0 }

      let position = self.position
      let index = jsFloor(position)
      let fraction = position - index
      let leftA = index >= 0 ? (left.at(index) ?? 0) : 0
      let leftB = index >= 0 ? (left.at(index + 1) ?? leftA) : 0
      let rightA = index >= 0 ? (right.at(index) ?? leftA) : 0
      let rightB = index >= 0 ? (right.at(index + 1) ?? rightA) : 0
      let l = leftA + (leftB - leftA) * fraction
      let r = rightA + (rightB - rightA) * fraction
      let gain = level[frame].isFinite ? Double(level[frame]) : 1
      outLeft[frame] = Float(l * gain)
      outRight[frame] = Float(r * gain)
      if position >= 0 { self.position += sourceRate / sampleRate }
    }
    lastBeat = transport.beat + transport.beatsPerBlock
  }
}
