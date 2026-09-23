import DriftboxDSP

/// A whole synth in one module: two oscillators, the engine's ladder and two envelopes. A port of
/// `modules/voice.ts`.
public struct VoiceModule {
  let sampleRate: Double
  var a = Osc()
  var b = Osc()
  var filter: Ladder
  var ampLevel = 0.0
  var ampStage = 0
  var filterLevel = 0.0
  var filterStage = 0
  var lastGate = 0
  /// Where the pitch is now, which is not where it was asked to be while a glide runs.
  var glided = Double.nan

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
    filter = Ladder(sampleRate: sampleRate)
  }

  /// One stage of an exponential envelope: 99% of the way to its target in `seconds`.
  @_noAllocation
  func rate(_ seconds: Double) -> Double {
    if !(seconds > 0) { return 1 }
    return 1 - expDSP(-4.605170185988091 / (seconds * sampleRate))
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let pitchIn = inlets[0]
    let gateIn = inlets[1]
    let cutoffIn = inlets[2]
    let out = outlets[0]
    let envOut = outlets[1]
    let tune = params[0]
    let shapeA = params[1]
    let shapeB = params[2]
    let detune = params[3]
    let mix = params[4]
    let width = params[5]
    let cutoffParam = params[6]
    let resonance = params[7]
    let envAmount = params[8]
    let keyTrack = params[9]
    let attack = params[10]
    let decay = params[11]
    let sustain = params[12]
    let release = params[13]
    let filterDecay = params[14]
    let glide = params[15]
    let level = params[16]

    for i in 0..<frames {
      let gate = gateIn[i] >= 0.5 ? 1 : 0
      if gate == 1 && lastGate == 0 {
        a.phase = 0
        b.phase = 0
        ampStage = 1
        filterStage = 1
      }
      lastGate = gate

      let wanted = Double(tune[i]) / 12 + Double(pitchIn[i])
      if !(glided == glided) { glided = wanted }
      let glideTime = Double(glide[i])
      if glideTime > 0 { glided += (wanted - glided) * rate(glideTime) } else { glided = wanted }

      let carrier = 65.40639132514966 * exp2(glided)

      if ampStage == 1 {
        ampLevel += (1 - ampLevel) * rate(Double(attack[i]))
        if ampLevel > 0.99 {
          ampStage = 2
          ampLevel = 1
        }
      } else if ampStage == 2 {
        ampLevel += (Double(sustain[i]) - ampLevel) * rate(Double(decay[i]))
        if gate == 0 { ampStage = 0 }
      } else {
        ampLevel += (0 - ampLevel) * rate(Double(release[i]))
      }
      if ampStage != 0 && gate == 0 { ampStage = 0 }

      if filterStage == 1 {
        filterLevel += (1 - filterLevel) * rate(Double(attack[i]))
        if filterLevel > 0.99 { filterStage = 0 }
      } else {
        filterLevel += (0 - filterLevel) * rate(Double(filterDecay[i]))
      }

      var dtA = carrier / sampleRate
      if dtA > 0.45 { dtA = 0.45 }
      var dtB = (carrier * exp2(Double(detune[i]) / 1200)) / sampleRate
      if dtB > 0.45 { dtB = 0.45 }
      let blend = Double(mix[i])
      let sample =
        a.next(dtA, shape: truncated(shapeA[i]), width: Double(width[i])) * (1 - blend)
        + b.next(dtB, shape: truncated(shapeB[i]), width: Double(width[i])) * blend

      var cutoff = Double(cutoffParam[i])
      cutoff *= exp2(filterLevel * Double(envAmount[i]))
      cutoff *= exp2(glided * Double(keyTrack[i]))
      if cutoffIn[i] != 0 { cutoff *= exp2(Double(cutoffIn[i])) }
      if cutoff < 20 { cutoff = 20 } else if cutoff > 18000 { cutoff = 18000 }

      let filtered = filter.process(sample, cutoff: cutoff, resonance: Double(resonance[i]))
      out[i] = Float(filtered * ampLevel * Double(level[i]))
      envOut[i] = Float(ampLevel)
    }
  }
}
