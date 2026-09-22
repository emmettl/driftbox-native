// Following an external MIDI clock. A port of `driftbox/packages/engine/src/midi-clock.ts`, whose
// comments hold the measurements behind every constant.
//
// A clock is 24 ticks a quarter note, and the tempo is not written anywhere: it has to be
// estimated from when the ticks arrive, which is jittery on any port. So a line is fitted through
// the last few dozen ticks, refitted with the outliers dropped, and the tempo read off its slope.

public var ticksPerQuarter: Int { 24 }
public var ticksPerStep: Int { 6 }

public enum ClockMessage: Equatable, Sendable {
  case tick
  case start
  case stop
  case `continue`
  /// Song position, in sixteenths from the top.
  case position(step: Int)

  /// From the bytes on the wire. Nil for anything that is not a clock message.
  public init?(bytes: [UInt8]) {
    guard let status = bytes.first else { return nil }
    switch status {
    case 0xF8: self = .tick
    case 0xFA: self = .start
    case 0xFB: self = .continue
    case 0xFC: self = .stop
    case 0xF2:
      guard bytes.count >= 3 else { return nil }
      self = .position(step: Int(bytes[1] & 0x7F) | (Int(bytes[2] & 0x7F) << 7))
    default: return nil
    }
  }

  public var bytes: [UInt8] {
    switch self {
    case .tick: return [0xF8]
    case .start: return [0xFA]
    case .continue: return [0xFB]
    case .stop: return [0xFC]
    case .position(let step):
      let clamped = max(0, min(0x3FFF, step))
      return [0xF2, UInt8(clamped & 0x7F), UInt8((clamped >> 7) & 0x7F)]
    }
  }
}

public struct ClockState: Equatable, Sendable {
  /// Nil until enough ticks have arrived to say.
  public var bpm: Double?
  public var running: Bool
  public var ticks: Int
}

/// The estimator. Times are milliseconds, on whatever clock the ticks are stamped with.
public struct ClockFollower: Sendable {
  static let window = 48
  static let minimum = 12
  static let minimumBPM = 20.0
  static let maximumBPM = 300.0
  /// Silence this long means the clock stopped, however it stopped.
  static let stallMilliseconds = 500.0
  /// A tick arriving this many ticks late is taken as ticks lost, not one late tick.
  static let dropThreshold = 1.75

  struct Line: Equatable {
    var slope: Double
    var intercept: Double
  }

  struct Sample {
    var index: Int
    var time: Double
  }

  var samples: [Sample] = []
  var nextIndex = 0
  var lastTime: Double?
  var tempo: Double?
  var line: Line?
  var playing = false
  var position = 0

  public init() {}

  public var state: ClockState { ClockState(bpm: tempo, running: playing, ticks: position) }
  public var step: Int { Int((Double(position) / Double(ticksPerStep)).rounded(.down)) }

  /// Where the external transport is, in ticks, at `time`, by the line.
  public func position(at time: Double) -> Double? {
    guard playing, let line, let lastTime else { return nil }
    return max(0, Double(position) + (time - lastTime) / line.slope)
  }

  public mutating func tick(at time: Double) -> ClockState {
    if let lastTime, time - lastTime > Self.stallMilliseconds { reset() }

    var advance = 1
    if let line {
      let predicted = (time - line.intercept) / line.slope
      let raw = predicted - Double(nextIndex - 1)
      if raw >= Self.dropThreshold { advance = max(1, min(8, Int(jsRoundClock(raw)))) }
    }

    nextIndex += advance - 1
    samples.append(Sample(index: nextIndex, time: time))
    nextIndex += 1
    lastTime = time
    if samples.count > Self.window { samples.removeFirst() }
    if playing { position += advance }

    tempo = fit()
    return state
  }

  public mutating func start() -> ClockState {
    reset()
    playing = true
    position = 0
    return state
  }

  public mutating func `continue`() -> ClockState {
    reset()
    playing = true
    return state
  }

  public mutating func stop() -> ClockState {
    playing = false
    return state
  }

  public mutating func locate(step: Int) -> ClockState {
    position = max(0, step) * ticksPerStep
    return state
  }

  public func lost(at now: Double) -> Bool {
    guard let lastTime else { return false }
    return now - lastTime > Self.stallMilliseconds
  }

  private mutating func reset() {
    samples.removeAll()
    nextIndex = 0
    lastTime = nil
    tempo = nil
    line = nil
  }

  private static func regress(_ samples: [Sample]) -> Line? {
    var meanIndex = 0.0
    var meanTime = 0.0
    for sample in samples {
      meanIndex += Double(sample.index)
      meanTime += sample.time
    }
    meanIndex /= Double(samples.count)
    meanTime /= Double(samples.count)
    var covariance = 0.0
    var variance = 0.0
    for sample in samples {
      let di = Double(sample.index) - meanIndex
      covariance += di * (sample.time - meanTime)
      variance += di * di
    }
    if variance == 0 { return nil }
    let slope = covariance / variance
    return Line(slope: slope, intercept: meanTime - slope * meanIndex)
  }

  private static func residual(_ sample: Sample, _ line: Line) -> Double {
    sample.time - (line.intercept + line.slope * Double(sample.index))
  }

  /// A line through the window, then again without the outliers: a tick that arrived late
  /// because the port hiccupped should not bend the tempo.
  private mutating func fit() -> Double? {
    guard samples.count >= Self.minimum, let first = Self.regress(samples) else { return nil }
    var total = 0.0
    for sample in samples { total += abs(Self.residual(sample, first)) }
    let limit = (total / Double(samples.count)) * 3
    let kept = samples.filter { abs(Self.residual($0, first)) <= limit }
    let second = kept.count >= Self.minimum ? Self.regress(kept) : nil
    let line = second ?? first

    let msPerTick = line.slope
    guard msPerTick > 0 else { return nil }
    self.line = line
    let bpm = 60000 / (msPerTick * Double(ticksPerQuarter))
    if !bpm.isFinite || bpm < Self.minimumBPM || bpm > Self.maximumBPM { return tempo }
    return bpm
  }
}

/// `Math.round`.
private func jsRoundClock(_ value: Double) -> Double {
  let floor = value.rounded(.down)
  return value - floor >= 0.5 ? floor + 1 : floor
}

// MARK: - What the sequencer does with it

/// What a clock message asks of the local transport: a tempo to follow, a transport move, both,
/// or nothing. A port of `clock-follow.ts`.
public struct ClockCommand: Equatable, Sendable {
  public var bpm: Double?
  public enum Transport: Equatable, Sendable {
    case start, resume, stop
  }
  public var transport: Transport?
  public var step: Int?

  public init(bpm: Double? = nil, transport: Transport? = nil, step: Int? = nil) {
    self.bpm = bpm
    self.transport = transport
    self.step = step
  }
}

/// Where the local transport is: its tempo, and its position in ticks at `time`, if known.
public struct LocalClockState: Sendable {
  public var bpm: Double
  public var ticks: Double?
  public var time: Double?

  public init(bpm: Double, ticks: Double? = nil, time: Double? = nil) {
    self.bpm = bpm
    self.ticks = ticks
    self.time = time
  }
}

private let tempoEpsilon = 0.05
/// Phase is pulled in over this many ticks: eight beats.
private let phaseCorrectionTicks = Double(ticksPerQuarter * 8)
private let phaseEpsilonTicks = 0.25
private let maximumPhaseCorrection = 2.0

public func followClock(
  _ message: ClockMessage, at time: Double, follower: inout ClockFollower, local: LocalClockState
) -> ClockCommand {
  switch message {
  case .tick:
    guard let bpm = follower.tick(at: time).bpm else { return ClockCommand() }
    let next = phaseLocked(bpm, follower: follower, local: local, eventTime: time)
    if abs(next - local.bpm) < tempoEpsilon { return ClockCommand() }
    return ClockCommand(bpm: next)
  case .start:
    let state = follower.start()
    return ClockCommand(bpm: state.bpm, transport: .start)
  case .continue:
    let state = follower.continue()
    return ClockCommand(bpm: state.bpm, transport: .resume, step: follower.step)
  case .stop:
    _ = follower.stop()
    return ClockCommand(transport: .stop)
  case .position(let step):
    _ = follower.locate(step: step)
    return ClockCommand()
  }
}

/// A tempo nudged so that the local transport's phase within the step drifts towards the
/// external one's, by no more than two bpm.
private func phaseLocked(_ bpm: Double, follower: ClockFollower, local: LocalClockState, eventTime: Double)
  -> Double
{
  guard let ticks = local.ticks, let external = follower.position(at: local.time ?? eventTime) else {
    return bpm
  }
  let error = phaseError(external: external, local: ticks)
  if abs(error) < phaseEpsilonTicks { return bpm }
  let correction = max(
    -maximumPhaseCorrection, min(maximumPhaseCorrection, (bpm * error) / phaseCorrectionTicks))
  return bpm + correction
}

/// How far ahead the external clock is, within a step, in ticks: -3 to 3.
private func phaseError(external: Double, local: Double) -> Double {
  let period = Double(ticksPerStep)
  let half = period / 2
  // `((x % p) + p) % p - half`, as the reference has it, with JavaScript's `%`.
  let shifted = external - local + half
  let wrapped = (shifted.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(
    dividingBy: period)
  return wrapped - half
}
