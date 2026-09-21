import DriftboxDSP
import DriftboxSeq

/// The authored master inserts: drive, a pattern-controlled low-pass mixed in beside the dry
/// signal, then the bus compressor. A port of `driftbox/packages/engine/src/master-effects.ts`.
///
/// These are part of the song rather than of the host around it — they travel with `FxParams` and
/// can be automated — so they sit before the performance filter, which is momentary.
public struct MasterInserts: ~Copyable {
  public let sampleRate: Double

  /// No curve at all when the drive is zero, and then the browser's waveshaper passes the signal
  /// straight through: no oversampling, and none of its 128 frames of delay. So turning the drive
  /// knob up from zero moves the whole mix 2.7ms later. Measured, and kept.
  /// Sixty-five curves, from clean to full, made once; the two shapers run over them and over
  /// history of their own, so a change of drive allocates nothing.
  static var curveShapes: Int { 65 }
  static var curveSamples: Int { 2048 }
  let curves: UnsafeMutablePointer<Float>
  let kernels: UnsafeMutablePointer<Float>
  let shaperState: UnsafeMutablePointer<Float>
  var driveLeft: WaveShaper.Core
  var driveRight: WaveShaper.Core
  var curveShape = -1

  var filterLeft: Biquad
  var filterRight: Biquad
  var cutoff: FixedTimeline
  var resonance: TargetSmoother
  var dry: TargetSmoother
  var wet: TargetSmoother

  var compressor: Compressor
  var threshold: TargetSmoother
  var ratio: TargetSmoother
  var knee: TargetSmoother
  var attack: TargetSmoother
  var release: TargetSmoother

  public init(sampleRate: Double) {
    self.sampleRate = sampleRate
    curves = .allocate(capacity: Self.curveShapes * Self.curveSamples)
    curves.initialize(repeating: 0, count: Self.curveShapes * Self.curveSamples)
    for shape in 1..<Self.curveShapes {
      for (index, value) in (Self.driveCurve(Double(shape) / 64) ?? []).enumerated() {
        curves[shape * Self.curveSamples + index] = value
      }
    }
    kernels = .allocate(capacity: WaveShaper.Core.kernelFloats)
    WaveShaper.Core.fillKernels(kernels)
    shaperState = .allocate(capacity: 2 * WaveShaper.Core.stateFloats)
    driveLeft = WaveShaper.Core(
      curve: curves, curveCount: 0, oversamples: false, kernels: kernels, state: shaperState)
    driveRight = WaveShaper.Core(
      curve: curves, curveCount: 0, oversamples: false, kernels: kernels,
      state: shaperState + WaveShaper.Core.stateFloats)
    filterLeft = Biquad(response: .lowpass, sampleRate: sampleRate)
    filterRight = Biquad(response: .lowpass, sampleRate: sampleRate)

    let defaults = FxParams()
    cutoff = FixedTimeline(defaultValue: Self.filterFrequency(defaults.pcfCutoff))
    resonance = TargetSmoother(value: Float(defaults.pcfResonance * 24), sampleRate: sampleRate)
    dry = TargetSmoother(value: 1, sampleRate: sampleRate)
    wet = TargetSmoother(value: 0, sampleRate: sampleRate)

    // The original fixed bus compressor, which a compressor knob at 0.5 reproduces exactly.
    let mix = Compressor.Settings(threshold: -14, knee: 8, ratio: 4, attack: 0.004, release: 0.18)
    compressor = Compressor(mix, sampleRate: sampleRate)
    threshold = TargetSmoother(value: mix.threshold, sampleRate: sampleRate)
    ratio = TargetSmoother(value: mix.ratio, sampleRate: sampleRate)
    knee = TargetSmoother(value: mix.knee, sampleRate: sampleRate)
    attack = TargetSmoother(value: mix.attack, sampleRate: sampleRate)
    release = TargetSmoother(value: mix.release, sampleRate: sampleRate)

    update(defaults, atFrame: 0)
  }

  deinit {
    curves.deallocate()
    kernels.deallocate()
    shaperState.deallocate()
  }

  @_noAllocation
  public static func filterFrequency(_ knob: Double) -> Double { 60 * powDSP(200, max(0, min(1, knob))) }
  @_noAllocation
  public static func filterDecaySeconds(_ knob: Double) -> Double { 0.025 + max(0, min(1, knob)) * 0.775 }

  /// `tanh`, steeper with the knob, scaled to pass ±1 through. Nil at zero: no curve, no shaper.
  public static func driveCurve(_ amount: Double) -> [Float]? {
    let value = max(0, min(1, amount))
    if value == 0 { return nil }
    let drive = 0.1 + value * 19.9
    let scale = 1 / tanhDSP(drive)
    let samples = 2048
    return (0..<samples).map { index in
      Float(tanhDSP((Double(index) / Double(samples - 1) * 2 - 1) * drive) * scale)
    }
  }

  /// Apply the song's insert settings from `frame` on, and strike the filter's envelope if this
  /// step asks for it.
  ///
  /// `scheduledAtFrame` is when the call is being made, and defaults to `frame`. A strike cancels
  /// the sweep of the one before it, and a sweep cancelled part-way keeps what had played — see
  /// `ParamTimeline.cancel`. The reference makes these calls from the start of a render quantum.
  @_noAllocation
  public mutating func update(
    _ fx: FxParams, atFrame frame: Int, strike: StepValue = .off, scheduledAtFrame: Int? = nil
  ) {
    let time = Double(frame) / sampleRate
    let scheduled = scheduledAtFrame ?? frame

    // Sixty-five shapes: finer than a knob can distinguish. The curve is not a parameter, so it
    // changes when the call is made.
    let shape = Int(jsRound(max(0, min(1, fx.drive)) * 64))
    if shape != curveShape {
      curveShape = shape
      let samples = 2048
      let curve = curves + shape * samples
      driveLeft = WaveShaper.Core(
        curve: curve, curveCount: shape == 0 ? 0 : samples, oversamples: shape != 0, kernels: kernels,
        state: shaperState)
      driveRight = WaveShaper.Core(
        curve: curve, curveCount: shape == 0 ? 0 : samples, oversamples: shape != 0, kernels: kernels,
        state: shaperState + 384)
    }

    let amount = max(0, min(1, fx.pcfAmount))
    dry.setTarget(Float(1 - amount), at: frame, timeConstant: 0.005)
    wet.setTarget(Float(amount), at: frame, timeConstant: 0.005)
    resonance.setTarget(Float(max(0, min(1, fx.pcfResonance)) * 24), at: frame, timeConstant: 0.01)

    let base = Self.filterFrequency(fx.pcfCutoff)
    cutoff.cancel(from: time, lastRendered: scheduled > 0 ? Double(scheduled - 1) / sampleRate : nil)
    cutoff.append(.set, value: base, at: time)
    let struck: Bool
    let accented: Bool
    switch strike {
    case .off:
      struck = false
      accented = false
    case .on:
      struck = true
      accented = false
    case .accent:
      struck = true
      accented = true
    }
    if struck, amount > 0 {
      let octaves = max(0, min(1, fx.pcfEnv)) * 5 * (accented ? 1.25 : 1)
      let peak = min(sampleRate * 0.45, base * powDSP(2, octaves))
      cutoff.append(.exponentialRamp, value: max(base, peak), at: time + 0.008)
      cutoff.append(.exponentialRamp, value: base, at: time + Self.filterDecaySeconds(fx.pcfDecay))
    }

    // 0.5 is the original compressor. The ends run from transparent to assertive without a second
    // loudness knob, because the makeup gain follows the curve.
    let compression = max(0, min(1, fx.compressor))
    threshold.setTarget(Float(-28 * compression), at: frame, timeConstant: 0.01)
    ratio.setTarget(Float(1 + compression * 6), at: frame, timeConstant: 0.01)
    knee.setTarget(8, at: frame, timeConstant: 0.01)
    attack.setTarget(0.004, at: frame, timeConstant: 0.01)
    release.setTarget(0.18, at: frame, timeConstant: 0.01)
  }

  /// One stereo frame through the inserts. Call once per frame, in order.
  @_noAllocation
  public mutating func process(left: Float, right: Float, frame: Int) -> (left: Float, right: Float) {
    let drivenLeft = driveLeft.process(left)
    let drivenRight = driveRight.process(right)

    let time = Double(frame) / sampleRate
    let frequency = Double(Float(cutoff.value(at: time)))
    let q = Double(resonance.next(frame: frame))
    filterLeft.set(frequency: frequency, q: q)
    filterRight.set(frequency: frequency, q: q)
    let dryGain = dry.next(frame: frame)
    let wetGain = wet.next(frame: frame)
    let mixedLeft = drivenLeft * dryGain + Float(filterLeft.process(Double(drivenLeft))) * wetGain
    let mixedRight = drivenRight * dryGain + Float(filterRight.process(Double(drivenRight))) * wetGain

    // The compressor's knobs are read once per render quantum.
    let settings = Compressor.Settings(
      threshold: threshold.next(frame: frame), knee: knee.next(frame: frame), ratio: ratio.next(frame: frame),
      attack: attack.next(frame: frame), release: release.next(frame: frame))
    if frame % 128 == 0 { compressor.set(settings) }
    return compressor.process(left: mixedLeft, right: mixedRight)
  }
}
