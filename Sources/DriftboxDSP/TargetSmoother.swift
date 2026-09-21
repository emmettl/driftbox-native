/// A parameter that only ever moves by `setTargetAtTime`: an exponential approach with a time
/// constant, which is how the send effects take every change to their knobs so that none of them
/// can click.
///
/// It is computed the way the browser computes it, which is not the closed form. A
/// single-precision value is stepped towards its target once per frame, and once per render
/// quantum the browser decides whether it has arrived, after which the value *is* the target,
/// exactly. For a gain the difference from the closed form is nothing. For a delay time it is
/// where the echo lands: seventeen thousand single-precision steps wander a few millionths of a
/// second from the curve, which is a sixteenth of a sample, and a delay line read a sixteenth of
/// a sample out is a different waveform. The closed form was tried, and was that far out.
public struct TargetSmoother {
  /// Frames per render quantum.
  public static let quantum = 128
  /// Arrived, if this close to a target, relative to the value …
  static let closeEnough: Float = 4.5e-5
  /// … or this close to a target of zero …
  static let closeEnoughToZero: Float = 1.5e-13
  /// … or after this many time constants whatever the value.
  static let timeConstantsToArrive = 10.0

  public let sampleRate: Double
  public private(set) var value: Float

  private var target: Float
  private var step: Float = 0
  private var startFrame = 0
  private var timeConstant = 0.0
  private var arrived = true
  private var pending: [(frame: Int, target: Float, timeConstant: Double)] = []

  public init(value: Float, sampleRate: Double) {
    self.value = value
    target = value
    self.sampleRate = sampleRate
  }

  /// Head for `target` from `frame` on. Calls must come in frame order.
  public mutating func setTarget(_ target: Float, at frame: Int, timeConstant: Double) {
    pending.append((frame, target, timeConstant))
  }

  /// The value for `frame`. Call once per frame, in order.
  public mutating func next(frame: Int) -> Float {
    while let first = pending.first, first.frame <= frame {
      pending.removeFirst()
      target = first.target
      timeConstant = first.timeConstant
      startFrame = first.frame
      step = Float(1 - dbExp(-1 / (sampleRate * first.timeConstant)))
      arrived = first.timeConstant <= 0
      if arrived { value = target }
    }

    if frame % Self.quantum == 0 || frame == startFrame {
      if !arrived {
        let elapsed = Double(frame - startFrame) / sampleRate
        let close =
          target == 0
          ? abs(value) < Self.closeEnoughToZero : abs(target - value) < Self.closeEnough * abs(value)
        if close || elapsed > Self.timeConstantsToArrive * timeConstant {
          value = target
          arrived = true
        }
      }
    }
    if arrived { return value }

    let now = value
    value += (target - value) * step
    return now
  }
}
