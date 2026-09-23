import DriftboxDSP

// The Alligator and the Vocoder, each a line-for-line port of its file in
// `driftbox/packages/rack/src/modules`. The family's processors are one enum here, behind one case
// of `RackProcessor`, so its modules can be added without touching anyone else's.
//
// As in `Basics.swift`, arithmetic is in doubles and every buffer write is rounded to float32,
// which is what JavaScript does with a Float32Array. The Alligator keeps its state in plain
// JavaScript arrays, so doubles; the Vocoder keeps its in Float32Arrays, so floats, rounded on
// every store and widened on every read.

public enum FilterProcessor {
  case alligator(AlligatorModule)
  case vocoder(VocoderModule)

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    switch self {
    case .alligator(var module):
      module.process(inlets, outlets, params, context)
      self = .alligator(module)
    case .vocoder(var module):
      module.process(inlets, outlets, params, context)
      self = .vocoder(module)
    }
  }

  func meter() -> MeterReading? { nil }

  mutating func release() {
    switch self {
    case .alligator(let module): module.release()
    case .vocoder(let module): module.release()
    }
  }
}

/// `Math.max(a, b)`, which answers NaN when either is, where Swift's `max` would not.
@_noAllocation
private func jsMax(_ a: Double, _ b: Double) -> Double {
  if a.isNaN || b.isNaN { return .nan }
  return a > b ? a : b
}

/// `Math.sqrt`, which is exact. A debug build does not inline the standard library's square root,
/// and `@_noAllocation` refuses a call it cannot see into, so it is vouched for here the way
/// `DriftboxDSP/Math.swift` vouches for libm.
@_semantics("no_performance_analysis") @inline(never)
private func squareRoot(_ x: Double) -> Double { x.squareRoot() }

/// The rack's 99%-in-the-stated-time coefficient for a timed knob, zero for no time at all.
@_noAllocation
private func timeCoefficient(_ seconds: Double, _ sampleRate: Double) -> Double {
  seconds <= 0 ? 0 : powDSP(0.01, 1 / jsMax(1, seconds * sampleRate))
}

// MARK: - Alligator

/// Three filtered gates across one signal: a lowpass, a bandpass and a highpass, each a
/// topology-preserving SVF, each multiplied by its own gate through an attack-release envelope.
public struct AlligatorModule {
  /// One band's filter and envelope, which the reference keeps as one plain array per field.
  struct Band {
    var ic1 = 0.0
    var ic2 = 0.0
    var level = 0.0
    var lastFrequency = Double.nan
    var a1 = 0.0
    var a2 = 0.0
    var a3 = 0.0
    var k = 0.0
    var lastDecay = Double.nan
    var decayCoefficient = 0.0
  }

  /// Lowpass, bandpass, highpass: the device, and the size of the reference's state arrays.
  static let bandCount = 3

  let sampleRate: Double
  let bands: UnsafeMutablePointer<Band>
  var lastAttack = Double.nan
  var attackCoefficient = 0.0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
    bands = .allocate(capacity: Self.bandCount)
    bands.initialize(repeating: Band(), count: Self.bandCount)
  }

  func release() { bands.deallocate() }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let input = inlets[0]
    let count = outlets.count
    let attackParam = params[0]
    let ceiling = sampleRate * 0.45

    for i in 0..<frames {
      let attack = Double(attackParam[i])
      if attack != lastAttack {
        lastAttack = attack
        attackCoefficient = timeCoefficient(attack, sampleRate)
      }

      let sample = Double(input[i])

      for band in 0..<count {
        // params: [0] attack, then a frequency, a resonance, a decay and a level per band.
        let frequency0 = Double(params[1 + band][i])
        let resonance = Double(params[1 + count + band][i])
        let decay = Double(params[1 + count * 2 + band][i])
        let gain = Double(params[1 + count * 3 + band][i])

        var frequency = frequency0
        if frequency < 20 { frequency = 20 } else if frequency > ceiling { frequency = ceiling }

        var res = resonance
        if res < 0 { res = 0 } else if res > 1 { res = 1 }
        let damping = 2 - 1.96 * res

        var state = bands[band]
        if frequency != state.lastFrequency {
          state.lastFrequency = frequency
          let g = tanDSP((Double.pi * frequency) / sampleRate)
          state.k = damping
          state.a1 = 1 / (1 + g * (g + damping))
          state.a2 = g * state.a1
          state.a3 = g * state.a2
        } else if damping != state.k {
          // Resonance moved but the frequency did not: g recovered from the cached coefficients,
          // as the reference does, rather than from another `tan`.
          let g = state.a2 / state.a1
          state.k = damping
          state.a1 = 1 / (1 + g * (g + damping))
          state.a2 = g * state.a1
          state.a3 = g * state.a2
        }

        let v3 = sample - state.ic2
        let v1 = state.a1 * state.ic1 + state.a2 * v3
        let v2 = state.ic2 + state.a2 * state.ic1 + state.a3 * v3
        state.ic1 = 2 * v1 - state.ic1
        state.ic2 = 2 * v2 - state.ic2

        // Band 0 is the lowpass, 1 the bandpass, 2 the highpass.
        let filtered = band == 1 ? v1 : band == 2 ? sample - state.k * v1 - v2 : v2

        if decay != state.lastDecay {
          state.lastDecay = decay
          state.decayCoefficient = timeCoefficient(decay, sampleRate)
        }

        // The gate, enveloped: an attack-release with the gate itself as the sustain.
        let target: Double = Double(inlets[1 + band][i]) >= 0.5 ? 1 : 0
        let coefficient = target > state.level ? attackCoefficient : state.decayCoefficient
        state.level = target + (state.level - target) * coefficient
        bands[band] = state

        outlets[band][i] = Float(filtered * state.level * gain)
      }
    }
  }
}

// MARK: - Vocoder

/// A bank of logarithmically spaced bandpass SVFs on the carrier and the modulator, an envelope
/// follower on each modulator band driving the carrier band `shift` above it.
public struct VocoderModule {
  /// The most bands the state is sized for; the `bands` param picks 8, 16 or 32 of them.
  static let maxBands = 32

  let sampleRate: Double
  /// One allocation, eight Float32Array(32)s: the carrier's and the modulator's two integrators,
  /// the follower, then the three cached coefficients.
  let storage: UnsafeMutablePointer<Float>
  let carrierIc1: UnsafeMutablePointer<Float>
  let carrierIc2: UnsafeMutablePointer<Float>
  let modIc1: UnsafeMutablePointer<Float>
  let modIc2: UnsafeMutablePointer<Float>
  let envelope: UnsafeMutablePointer<Float>
  let a1: UnsafeMutablePointer<Float>
  let a2: UnsafeMutablePointer<Float>
  let a3: UnsafeMutablePointer<Float>
  var damping = 0.0
  var lastBands = 0

  var lastAttack = Double.nan
  var lastRelease = Double.nan
  var attackCoefficient = 0.0
  var releaseCoefficient = 0.0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
    let n = Self.maxBands
    storage = .allocate(capacity: n * 8)
    storage.initialize(repeating: 0, count: n * 8)
    carrierIc1 = storage
    carrierIc2 = storage + n
    modIc1 = storage + n * 2
    modIc2 = storage + n * 3
    envelope = storage + n * 4
    a1 = storage + n * 5
    a2 = storage + n * 6
    a3 = storage + n * 7
  }

  func release() { storage.deallocate() }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let carrierIn = inlets[0]
    let modIn = inlets[1]
    let out = outlets[0]

    // Read once per block: selectors, not things you sweep.
    var selector = jsRound(Double(params[0][0]))
    if selector < 0 { selector = 0 } else if selector > 2 { selector = 2 }
    // `8 << selector`, where a NaN selector shifts by nothing.
    let bands = 8 << (selector.isNaN ? 0 : Int(selector))
    let attack = Double(params[1][0])
    let release = Double(params[2][0])
    let shift = jsRound(Double(params[3][0]))
    let dry = Double(params[4][0])

    if bands != lastBands {
      lastBands = bands
      damping = 2 / squareRoot(Double(bands))
      if damping < 0.08 { damping = 0.08 }
      let ceiling = sampleRate * 0.45
      for band in 0..<bands {
        let t = bands == 1 ? 0 : Double(band) / Double(bands - 1)
        var frequency = 110 * powDSP(7000.0 / 110.0, t)
        if frequency > ceiling { frequency = ceiling }
        let g = tanDSP((Double.pi * frequency) / sampleRate)
        a1[band] = Float(1 / (1 + g * (g + damping)))
        a2[band] = Float(g * Double(a1[band]))
        a3[band] = Float(g * Double(a2[band]))
      }
      // State from a different band layout is meaningless.
      for index in 0..<Self.maxBands * 5 { storage[index] = 0 }
    }

    if attack != lastAttack {
      lastAttack = attack
      attackCoefficient = timeCoefficient(attack, sampleRate)
    }
    if release != lastRelease {
      lastRelease = release
      releaseCoefficient = timeCoefficient(release, sampleRate)
    }

    let makeup = squareRoot(Double(bands)) * 0.7

    for i in 0..<frames {
      let carrierSample = Double(carrierIn[i])
      let modSample = Double(modIn[i])
      var sum = 0.0

      for band in 0..<bands {
        // The modulator's band, and how loud it is; the bandpass output is `v1`.
        let mv3 = modSample - Double(modIc2[band])
        let mv1 = Double(a1[band]) * Double(modIc1[band]) + Double(a2[band]) * mv3
        let mv2 = Double(modIc2[band]) + Double(a2[band]) * Double(modIc1[band]) + Double(a3[band]) * mv3
        modIc1[band] = Float(2 * mv1 - Double(modIc1[band]))
        modIc2[band] = Float(2 * mv2 - Double(modIc2[band]))

        let level = mv1 < 0 ? -mv1 : mv1
        let coefficient = level > Double(envelope[band]) ? attackCoefficient : releaseCoefficient
        envelope[band] = Float(level + (Double(envelope[band]) - level) * coefficient)

        // The carrier's band.
        let cv3 = carrierSample - Double(carrierIc2[band])
        let cv1 = Double(a1[band]) * Double(carrierIc1[band]) + Double(a2[band]) * cv3
        let cv2 =
          Double(carrierIc2[band]) + Double(a2[band]) * Double(carrierIc1[band]) + Double(a3[band]) * cv3
        carrierIc1[band] = Float(2 * cv1 - Double(carrierIc1[band]))
        carrierIc2[band] = Float(2 * cv2 - Double(carrierIc2[band]))

        // The shift: carrier band n driven by modulator band n - shift, silence off either end.
        let source = Double(band) - shift
        let gain = source >= 0 && source < Double(bands) ? Double(envelope[Int(source)]) : 0
        sum += cv1 * gain
      }

      let wet = sum * makeup
      let value = wet + carrierSample * dry
      out[i] = Float(value > 4 ? 4 : value < -4 ? -4 : value)
    }
  }
}

// MARK: - Definitions

extension RackModules {
  static let filterDefs: [ModuleDef] = [alligatorDef, vocoderDef]

  static func makeFilter(_ type: String, sampleRate: Double, id: String, voice: VoiceInfo)
    -> FilterProcessor?
  {
    switch type {
    case "alligator": .alligator(AlligatorModule(sampleRate: sampleRate))
    case "vocoder": .vocoder(VocoderModule(sampleRate: sampleRate))
    default: nil
    }
  }

  static let alligatorDef = ModuleDef(
    type: "alligator", name: "Alligator",
    inlets: [
      Port("in", "In"), Port("gate1", "Low Gate"), Port("gate2", "Band Gate"), Port("gate3", "High Gate"),
    ],
    outlets: [Port("out1", "Low"), Port("out2", "Band"), Port("out3", "High")],
    params: [
      ParamDef("attack", "Attack", min: 0.0005, max: 0.2, default: 0.003),
      ParamDef("freq1", "Low Freq", min: 20, max: 18000, default: 220),
      ParamDef("freq2", "Band Freq", min: 20, max: 18000, default: 1200),
      ParamDef("freq3", "High Freq", min: 20, max: 18000, default: 4000),
      ParamDef("res1", "Low Res", min: 0, max: 1, default: 0.2),
      ParamDef("res2", "Band Res", min: 0, max: 1, default: 0.5),
      ParamDef("res3", "High Res", min: 0, max: 1, default: 0.2),
      ParamDef("decay1", "Low Decay", min: 0.001, max: 2, default: 0.25),
      ParamDef("decay2", "Band Decay", min: 0.001, max: 2, default: 0.12),
      ParamDef("decay3", "High Decay", min: 0.001, max: 2, default: 0.06),
      ParamDef("level1", "Low Level", min: 0, max: 2, default: 1),
      ParamDef("level2", "Band Level", min: 0, max: 2, default: 1),
      ParamDef("level3", "High Level", min: 0, max: 2, default: 1),
    ])

  static let vocoderDef: ModuleDef = {
    var def = ModuleDef(
      type: "vocoder", name: "Vocoder", inlets: [Port("carrier", "Carrier"), Port("mod", "Mod")],
      outlets: [Port("out", "Out")],
      params: [
        ParamDef("bands", "Bands", min: 0, max: 2, default: 1, stepped: true),
        ParamDef("attack", "Attack", min: 0.0005, max: 0.2, default: 0.004),
        ParamDef("release", "Release", min: 0.001, max: 1, default: 0.05),
        ParamDef("shift", "Shift", min: -12, max: 12, default: 0, stepped: true),
        ParamDef("dry", "Dry", min: 0, max: 1, default: 0),
      ])
    def.poly = false
    return def
  }()
}
