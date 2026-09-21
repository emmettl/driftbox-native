/// The browser's `DynamicsCompressorNode`.
///
/// The Web Audio specification says what this node's knobs are called and nothing about how it
/// behaves, so "the compressor" in the reference means one particular implementation — the one in
/// Chromium, inherited from WebKit — and every catalogue song was mixed through it. It is a
/// characterful design rather than a textbook one, and this follows it move for move:
///
/// - It **looks ahead** six milliseconds: the signal is delayed while the detector reads it
///   undelayed, so the gain is already coming down when a transient arrives.
/// - The static curve is linear to the threshold, an exponential **soft knee** above it, and the
///   ratio above that, with the knee's steepness found by bisection so the three join smoothly.
/// - **Makeup gain is automatic**: what the curve would do to a full-scale signal, inverted and
///   raised to the 0.6. Below the threshold everything comes out about 1.7 times louder.
/// - The detector follows attenuation, not level, and releases at a rate that depends on how far
///   it has to go. The gain itself moves in steps of 32 frames, with an **adaptive release** — a
///   quartic through four fractions of the release time, faster the harder it was compressing.
/// - The gain is shaped through a sine on the way out, which rounds the corners where an attack
///   turns into a release.
/// - Two channels are linked: it listens to whichever side is louder and turns both down.
///
/// It also starts from a detector at zero, so the first fifty milliseconds of any render duck and
/// recover. That is in the reference's mixes too.
///
/// The arithmetic is single precision throughout, as the original's is.
public struct Compressor: ~Copyable {
  public struct Settings: Equatable, Sendable {
    /// Decibels. Where compression begins.
    public var threshold: Float
    /// Decibels above the threshold over which the curve bends towards the ratio.
    public var knee: Float
    public var ratio: Float
    /// Seconds.
    public var attack: Float
    public var release: Float

    @_noAllocation
    public init(threshold: Float, knee: Float, ratio: Float, attack: Float, release: Float) {
      self.threshold = threshold
      self.knee = knee
      self.ratio = ratio
      self.attack = attack
      self.release = release
    }
  }

  static var divisionFrames: Int { 32 }
  static var maximumDelayFrames: Int { 1024 }
  static var lookaheadSeconds: Double { 0.006 }
  static var detectorReleaseSeconds: Float { 0.0025 }

  public let sampleRate: Float
  /// How many frames late the output is.
  public let latency: Int

  let delayLeft: UnsafeMutablePointer<Float>
  let delayRight: UnsafeMutablePointer<Float>
  var readIndex = 0
  var writeIndex: Int

  var detectorAverage: Float = 0
  var gain: Float = 1
  var largestAttackDifference: Float = -1

  // The static curve, recomputed when a knob moves.
  var settings: Settings
  var linearThreshold: Float = 0
  var kneeThreshold: Float = 0
  var kneeThresholdDecibels: Float = 0
  var kneeOutputDecibels: Float = 0
  var slope: Float = 0
  var k: Float = 0
  var makeup: Float = 1

  // This division's envelope, decided at its first frame.
  var frameInDivision = 0
  var envelopeRate: Float = 0
  var desiredGain: Float = 0

  public init(_ settings: Settings, sampleRate: Double) {
    self.sampleRate = Float(sampleRate)
    latency = min(Self.maximumDelayFrames - 1, Int(Self.lookaheadSeconds * sampleRate))
    writeIndex = latency
    delayLeft = .allocate(capacity: Self.maximumDelayFrames)
    delayRight = .allocate(capacity: Self.maximumDelayFrames)
    delayLeft.initialize(repeating: 0, count: Self.maximumDelayFrames)
    delayRight.initialize(repeating: 0, count: Self.maximumDelayFrames)
    self.settings = settings
    updateCurve()
  }

  deinit {
    delayLeft.deallocate()
    delayRight.deallocate()
  }

  @_noAllocation
  public mutating func set(_ new: Settings) {
    guard new != settings else { return }
    let curveChanged =
      new.threshold != settings.threshold || new.knee != settings.knee || new.ratio != settings.ratio
    settings = new
    if curveChanged { updateCurve() }
  }

  // MARK: - The static curve

  /// Linear to the threshold; above it, an exponential approach whose steepness is `k`.
  @_noAllocation
  func kneeCurve(_ x: Float, _ k: Float) -> Float {
    x < linearThreshold ? x : linearThreshold + (1 - expf(-k * (x - linearThreshold))) / k
  }

  /// The whole curve: the knee, and the ratio above where the knee ends.
  @_noAllocation
  func saturate(_ x: Float, _ k: Float) -> Float {
    if x < kneeThreshold { return kneeCurve(x, k) }
    return fromDecibels(kneeOutputDecibels + slope * (toDecibels(x) - kneeThresholdDecibels))
  }

  @_noAllocation
  func slopeAt(_ x: Float, _ k: Float) -> Float {
    if x < linearThreshold { return 1 }
    let x2 = x * 1.001
    return (toDecibels(kneeCurve(x2, k)) - toDecibels(kneeCurve(x, k))) / (toDecibels(x2) - toDecibels(x))
  }

  @_noAllocation
  mutating func updateCurve() {
    linearThreshold = fromDecibels(settings.threshold)
    slope = 1 / settings.ratio

    // The knee's steepness, found by bisection: the one that leaves the knee at the ratio's slope.
    let kneeEnd = fromDecibels(settings.threshold + settings.knee)
    var low: Float = 0.1
    var high: Float = 10000
    var candidate: Float = 5
    for _ in 0..<15 {
      if slopeAt(kneeEnd, candidate) < slope { high = candidate } else { low = candidate }
      candidate = Float(dbPow(Double(low * high), 0.5))
    }
    k = candidate

    kneeThresholdDecibels = settings.threshold + settings.knee
    kneeThreshold = fromDecibels(kneeThresholdDecibels)
    kneeOutputDecibels = toDecibels(kneeCurve(kneeThreshold, k))

    // What the curve does to full scale, undone — and then not all of it, by ear.
    makeup = powf(1 / saturate(1, k), 0.6)
  }

  // MARK: - Processing

  /// One stereo frame. The output is `latency` frames behind the input.
  @_noAllocation
  public mutating func process(left: Float, right: Float) -> (left: Float, right: Float) {
    if frameInDivision == 0 { beginDivision() }
    frameInDivision = (frameInDivision + 1) % Self.divisionFrames

    delayLeft[writeIndex] = left
    delayRight[writeIndex] = right

    // The detector: how much the curve would turn this frame down, followed instantly on the way
    // down and released at a rate that depends on how far down it is.
    let level = max(abs(left), abs(right))
    let attenuation = level <= 0.0001 ? 1 : saturate(level, k) / level
    let attenuationDecibels = max(2, -toDecibels(attenuation))
    let detectorReleaseRate =
      fromDecibels(attenuationDecibels / (Self.detectorReleaseSeconds * sampleRate)) - 1
    detectorAverage +=
      (attenuation - detectorAverage) * (attenuation > detectorAverage ? detectorReleaseRate : 1)
    detectorAverage = min(1, detectorAverage)
    if !detectorAverage.isFinite { detectorAverage = 1 }

    if envelopeRate < 1 {
      gain += (desiredGain - gain) * envelopeRate
    } else {
      gain = min(1, gain * envelopeRate)
    }

    // Through a sine, which rounds the corner where an attack turns into a release.
    let total = makeup * sinf(0.5 * Float.pi * gain)
    let out = (delayLeft[readIndex] * total, delayRight[readIndex] * total)
    readIndex = (readIndex + 1) & (Self.maximumDelayFrames - 1)
    writeIndex = (writeIndex + 1) & (Self.maximumDelayFrames - 1)
    return out
  }

  /// Every 32 frames: where the gain is heading, and how fast.
  @_noAllocation
  mutating func beginDivision() {
    // Warped to undo the sine on the way out.
    desiredGain = asinf(detectorAverage) / (0.5 * Float.pi)
    var difference = toDecibels(gain / desiredGain)

    if desiredGain > gain {
      // Releasing. The harder it was compressing, the faster it lets go: a quartic through four
      // fractions of the release time, read at how far there is to go.
      largestAttackDifference = -1
      if !difference.isFinite { difference = -1 }
      let x = 0.25 * (min(0, max(-12, difference)) + 12)
      let frames = settings.release * sampleRate
      let y1 = frames * 0.09
      let y2 = frames * 0.16
      let y3 = frames * 0.42
      let y4 = frames * 0.98
      let a =
        0.9999999999999998 * y1 + 1.8432219684323923e-16 * y2 - 1.9373394351676423e-16 * y3
        + 8.824516011816245e-18 * y4
      let b =
        -1.5788320352845888 * y1 + 2.3305837032074286 * y2 - 0.9141194204840429 * y3 + 0.1623677525612032 * y4
      let c =
        0.5334142869106424 * y1 - 1.272736789213631 * y2 + 0.9258856042207512 * y3 - 0.18656310191776226 * y4
      let d =
        0.08783463138207234 * y1 - 0.1694162967925622 * y2 + 0.08588057951595272 * y3 - 0.00429891410546283
        * y4
      let e =
        -0.042416883008123074 * y1 + 0.1115693827987602 * y2 - 0.09764676325265872 * y3 + 0.028494263462021576
        * y4
      let x2 = x * x
      let releaseFrames = a + b * x + c * x2 + d * x2 * x + e * x2 * x2
      envelopeRate = fromDecibels(5 / releaseFrames)
    } else {
      // Attacking, at a rate set by the largest difference seen since the attack began.
      if !difference.isFinite { difference = 1 }
      if largestAttackDifference == -1 || largestAttackDifference < difference {
        largestAttackDifference = difference
      }
      let attackFrames = max(0.001, settings.attack) * sampleRate
      envelopeRate = 1 - powf(0.25 / max(0.5, largestAttackDifference), 1 / attackFrames)
    }
  }
}

// Single-precision maths, by way of the double-precision functions already vouched for.

@_noAllocation
func toDecibels(_ linear: Float) -> Float { 20 * Float(dbLog(Double(linear)) / 2.302585092994045684) }
@_noAllocation
func fromDecibels(_ decibels: Float) -> Float { powf(10, 0.05 * decibels) }
@_noAllocation
func powf(_ base: Float, _ exponent: Float) -> Float { Float(dbPow(Double(base), Double(exponent))) }
@_noAllocation
func expf(_ x: Float) -> Float { Float(dbExp(Double(x))) }
@_noAllocation
func sinf(_ x: Float) -> Float { Float(dbSin(Double(x))) }
@_noAllocation
func asinf(_ x: Float) -> Float { Float(dbAsin(Double(x))) }
