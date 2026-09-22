import DriftboxDSP

/// A module's buffers for one block: a table of pointers, one per slot, in the def's order with a
/// stereo port taking two. Unpatched inlets all point at the one zero buffer, so a module never
/// asks whether it is patched; it must never write to an inlet, and must write every sample of
/// every outlet.
public struct Slots {
  let base: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
  public let count: Int

  @_noAllocation
  public subscript(index: Int) -> UnsafeMutablePointer<Float> { base[index] }
}

/// A module, running. One case per module type, so dispatch is a switch rather than a protocol
/// witness — the render path takes no existential and no class, and adding a module is adding a
/// case here and a def in `RackModules`.
public enum RackProcessor {
  case out
  case vco(VCO)
  case noise(NoiseSource)
  case vca
  case mixer
  case ladder(LadderModule)
  case svf(SVF)
  case adsr(ADSR)
  case lfo(LFO)
  case offset
  case sampleHold(SampleHold)
  case delay(Delay)
  // The rest of the modules, a family to an enum, each in its own file.
  case shaping(ShapingProcessor)
  case space(SpaceProcessor)
  case control(ControlProcessor)
  case sources(SourceProcessor)
  case sequencing(SequencingProcessor)
  case players(PlayerProcessor)

  @_noAllocation
  mutating func process(inlets: Slots, outlets: Slots, params: Slots, context: ProcessContext) {
    switch self {
    case .out: Out.process(inlets, outlets, params, context)
    case .vco(var module):
      module.process(inlets, outlets, params, context)
      self = .vco(module)
    case .noise(var module):
      module.process(inlets, outlets, params, context)
      self = .noise(module)
    case .vca: VCA.process(inlets, outlets, params, context)
    case .mixer: Mixer.process(inlets, outlets, params, context)
    case .ladder(var module):
      module.process(inlets, outlets, params, context)
      self = .ladder(module)
    case .svf(var module):
      module.process(inlets, outlets, params, context)
      self = .svf(module)
    case .adsr(var module):
      module.process(inlets, outlets, params, context)
      self = .adsr(module)
    case .lfo(var module):
      module.process(inlets, outlets, params, context)
      self = .lfo(module)
    case .offset: Offset.process(inlets, outlets, params, context)
    case .sampleHold(var module):
      module.process(inlets, outlets, params, context)
      self = .sampleHold(module)
    case .delay(var module):
      module.process(inlets, outlets, params, context)
      self = .delay(module)
    case .shaping(var family):
      family.process(inlets, outlets, params, context)
      self = .shaping(family)
    case .space(var family):
      family.process(inlets, outlets, params, context)
      self = .space(family)
    case .control(var family):
      family.process(inlets, outlets, params, context)
      self = .control(family)
    case .sources(var family):
      family.process(inlets, outlets, params, context)
      self = .sources(family)
    case .sequencing(var family):
      family.process(inlets, outlets, params, context)
      self = .sequencing(family)
    case .players(var family):
      family.process(inlets, outlets, params, context)
      self = .players(family)
    }
  }

  /// What the module shows its faceplate, for the few that show anything.
  func meter() -> MeterReading? {
    switch self {
    case .shaping(let family): family.meter()
    case .space(let family): family.meter()
    case .control(let family): family.meter()
    case .sources(let family): family.meter()
    case .sequencing(let family): family.meter()
    case .players(let family): family.meter()
    default: nil
    }
  }

  /// Give back what the processor allocated, when the graph that made it is done with it.
  mutating func release() {
    switch self {
    case .delay(let module): module.buffer.deallocate()
    case .shaping(var family): family.release()
    case .space(var family): family.release()
    case .control(var family): family.release()
    case .sources(var family): family.release()
    case .sequencing(var family): family.release()
    case .players(var family): family.release()
    default: break
    }
  }
}

// MARK: - Shared DSP

/// A PolyBLEP saw and pulse and a naive triangle. A port of `dsp/osc.ts`.
public struct Osc {
  var phase = 0.0

  @_noAllocation
  mutating func next(_ dt: Double, shape: Int, width: Double) -> Double {
    phase += dt
    if phase >= 1 { phase -= 1 }
    let t = phase
    if shape == 1 {
      var pw = width
      if pw < 0.05 { pw = 0.05 } else if pw > 0.95 { pw = 0.95 }
      var value: Double = t < pw ? 1 : -1
      value += Self.blep(t, dt)
      var fall = t - pw
      if fall < 0 { fall += 1 }
      return value - Self.blep(fall, dt)
    }
    if shape == 2 { return 1 - 4 * abs(t - 0.5) }
    return 2 * t - 1 - Self.blep(t, dt)
  }

  @_noAllocation
  static func blep(_ t: Double, _ dt: Double) -> Double {
    if t < dt {
      let x = t / dt
      return x + x - x * x - 1
    }
    if t > 1 - dt {
      let x = (t - 1) / dt
      return x * x + x + x + 1
    }
    return 0
  }
}

/// Xorshift32, seeded from a module's id by FNV-1a. A port of `dsp/random.ts`, down to the
/// reference's own arithmetic: its hash multiplies in doubles, which past 2^53 rounds before it is
/// truncated to 32 bits, so this does the same rather than a true 32-bit multiply.
public struct RackRandom {
  var state: UInt32

  public init(seed: String) {
    var hash: Int32 = Int32(bitPattern: 0x811c_9dc5)
    for unit in seed.utf16 {
      hash ^= Int32(unit)
      let product = Double(hash) * 16_777_619.0
      hash = Int32(truncatingIfNeeded: Int64(product))
    }
    state = hash == 0 ? 0x9e37_79b9 : UInt32(bitPattern: hash)
  }

  @_noAllocation
  public mutating func next() -> Double {
    var x = state
    x ^= x << 13
    x ^= x >> 17
    x ^= x << 5
    state = x
    return Double(Int32(bitPattern: x)) / 2_147_483_648
  }
}

/// `Math.pow(2, x)`, which the reference calls in the innermost loops.
@_noAllocation
func exp2(_ x: Double) -> Double { powDSP(2, x) }

/// `x | 0` on a float32 value: toward zero, as an integer.
@_noAllocation
func truncated(_ x: Float) -> Int { x.isFinite && abs(x) < 1e9 ? Int(x) : 0 }
