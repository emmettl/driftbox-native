import Synchronization

/// Sound coming in live — a microphone, an interface's inputs — on its way from the device's
/// thread to the rack's render thread, which reads it as input bus 4: the Audio Input module's.
///
/// A ring of stereo frames with one writer and one reader and no lock. The two threads run on
/// clocks of their own, which never quite agree, and hand over in pieces of different sizes, so
/// the reader keeps a little in hand — `hold` frames, which the writer sets from the size of its
/// pieces — and waits until it has that much before it starts, and again after it runs dry. When
/// it has fallen well behind, as it has after a stall, it skips to the newest `hold` frames rather
/// than be late from then on.
public final class LiveInput: @unchecked Sendable {
  /// Frames the ring holds: a third of a second at 48 kHz, far more than is ever kept.
  public static var capacity: Int { 16384 }
  /// The capacity again, for the threads that may not ask the type.
  private let size = LiveInput.capacity
  private let left: UnsafeMutablePointer<Float>
  private let right: UnsafeMutablePointer<Float>
  /// Frames ever written, and ever read. Each is stored by one thread only.
  private let written = Atomic<Int>(0)
  private let taken = Atomic<Int>(0)
  /// Frames ever handed in, whether or not they fitted.
  private let arrived = Atomic<Int>(0)
  /// How much the reader keeps in hand.
  private let hold = Atomic<Int>(1024)
  /// Whether the reader is waiting to have `hold` frames before it takes any. The reader's alone.
  private let priming: UnsafeMutablePointer<Bool>

  public init() {
    left = .allocate(capacity: Self.capacity)
    left.initialize(repeating: 0, count: Self.capacity)
    right = .allocate(capacity: Self.capacity)
    right.initialize(repeating: 0, count: Self.capacity)
    priming = .allocate(capacity: 1)
    priming.initialize(to: true)
  }

  deinit {
    left.deallocate()
    right.deallocate()
    priming.deallocate()
  }

  /// Every frame that has come in since the ring was made, kept or not: how fast a device is
  /// giving them, for a test to count.
  public var received: Int { arrived.load(ordering: .relaxed) }

  // MARK: - From the device's thread

  /// Before a device starts writing: keep `frames` in hand, which should cover the device's
  /// pieces arriving while the rack takes its own.
  public func prepare(hold frames: Int) {
    hold.store(min(Self.capacity / 4, max(256, frames)), ordering: .relaxed)
  }

  /// `frames` frames of `channels` interleaved channels: the first two as left and right, and a
  /// single channel as both. What does not fit is dropped; the reader is far behind by then and
  /// is about to skip what it has not read anyway.
  @_noAllocation
  public func write(_ samples: UnsafePointer<Float>, frames: Int, channels: Int) {
    guard channels > 0 else { return }
    arrived.add(frames, ordering: .relaxed)
    let at = written.load(ordering: .relaxed)
    let count = min(frames, size - (at - taken.load(ordering: .acquiring)))
    let second = channels > 1 ? 1 : 0
    for frame in 0..<max(0, count) {
      let slot = (at + frame) & (size - 1)
      left[slot] = samples[frame * channels]
      right[slot] = samples[frame * channels + second]
    }
    if count > 0 { written.store(at + count, ordering: .releasing) }
  }

  /// `frames` frames of nothing, which is what a device says when it has nothing to say.
  @_noAllocation
  public func writeSilence(frames: Int) {
    arrived.add(frames, ordering: .relaxed)
    let at = written.load(ordering: .relaxed)
    let count = min(frames, size - (at - taken.load(ordering: .acquiring)))
    for frame in 0..<max(0, count) {
      let slot = (at + frame) & (size - 1)
      left[slot] = 0
      right[slot] = 0
    }
    if count > 0 { written.store(at + count, ordering: .releasing) }
  }

  // MARK: - From the render thread

  /// The next `frames` frames into `left` and `right`, or silence for whatever there is not yet.
  @_noAllocation
  public func read(
    frames: Int, left out: UnsafeMutablePointer<Float>, right outRight: UnsafeMutablePointer<Float>
  ) {
    let end = written.load(ordering: .acquiring)
    var at = taken.load(ordering: .relaxed)
    let hold = hold.load(ordering: .relaxed)
    if priming.pointee {
      if end - at < hold {
        out.update(repeating: 0, count: frames)
        outRight.update(repeating: 0, count: frames)
        return
      }
      priming.pointee = false
    }
    // Fallen behind: the newest `hold` frames, rather than late from now on.
    if end - at > hold * 2 + frames { at = end - hold }
    let count = min(frames, end - at)
    for frame in 0..<count {
      let slot = (at + frame) & (size - 1)
      out[frame] = left[slot]
      outRight[frame] = right[slot]
    }
    if count < frames {
      (out + count).update(repeating: 0, count: frames - count)
      (outRight + count).update(repeating: 0, count: frames - count)
      priming.pointee = true
    }
    taken.store(at + count, ordering: .releasing)
  }
}
