/// The tail of a long convolution, its work spread evenly over the frames rather than done all at
/// once at the end of each block.
///
/// `PartitionedConvolver` works out the next block's output when a block of input is complete,
/// because its first transformed partition is due the moment the next block starts. With blocks
/// of 1,024, that is every partition of a three-second room multiplied and summed, and two
/// transforms of 2,048, in whichever render callback the block ends in: on a Fairphone 6 a call
/// every 21ms took twice as long as the rest. Here the response's first two blocks are empty —
/// they are the head's, in `Reverb` — so a block's contribution is not due until a whole block
/// after it is complete, and that block's time is used to work it out, in `steps` even parts: the
/// input's transform, a share of the partitions, and the inverse transform, each at its own frame.
/// The same answer as `PartitionedConvolver` over the same response, summed in the same order.
/// Owns raw storage and is not copyable, so `process` is allocation-free.
public struct SpreadConvolver: ~Copyable {
  public let block: Int
  let size: Int
  /// Counting the two empty ones at the start, which are never multiplied.
  public let partitions: Int
  /// Into how many parts a block's work is cut: one at the end of each eighth of the block but the
  /// last, where the block's result is put in place.
  public static var steps: Int { 8 }
  let stride: Int
  /// Single-precision spectra, `size` complex bins per partition, interleaved real/imaginary.
  let response: UnsafeMutablePointer<Float>
  let history: UnsafeMutablePointer<Float>
  let twiddles: UnsafeMutablePointer<Float>
  let reversal: UnsafeMutablePointer<Int>
  /// The sum being worked out for the block after next, and then its inverse transform.
  let sum: UnsafeMutablePointer<Float>
  /// What the transformed partitions contribute to the current block and the one after it.
  let current: UnsafeMutablePointer<Float>
  let carry: UnsafeMutablePointer<Float>
  /// The block coming in, and the one before it, whose contribution is being worked out.
  let input: UnsafeMutablePointer<Float>
  let finished: UnsafeMutablePointer<Float>
  var filled = 0
  var newest = 0
  /// Scaled by this on the way out, as `ConvolverNode` scales.
  public var gain: Float

  /// A response whose first `2 * block` taps are zero; anything there is not applied.
  public init(response taps: [Float], block: Int = 1024, gain: Float = 1) {
    precondition(block > 0 && block & (block - 1) == 0 && block % Self.steps == 0)
    self.block = block
    size = block * 2
    partitions = max(3, (taps.count + block - 1) / block)
    stride = block / Self.steps
    self.gain = gain

    twiddles = .allocate(capacity: size)
    reversal = .allocate(capacity: size)
    sum = .allocate(capacity: size * 2)
    current = .allocate(capacity: block)
    carry = .allocate(capacity: block)
    input = .allocate(capacity: block)
    finished = .allocate(capacity: block)
    sum.initialize(repeating: 0, count: size * 2)
    current.initialize(repeating: 0, count: block)
    carry.initialize(repeating: 0, count: block)
    input.initialize(repeating: 0, count: block)
    finished.initialize(repeating: 0, count: block)
    PartitionedConvolver.prepare(size: size, twiddles: twiddles, reversal: reversal)

    response = .allocate(capacity: partitions * size * 2)
    response.initialize(repeating: 0, count: partitions * size * 2)
    history = .allocate(capacity: partitions * size * 2)
    history.initialize(repeating: 0, count: partitions * size * 2)
    for partition in 2..<partitions {
      let spectrum = response + partition * size * 2
      for index in 0..<block {
        let tap = partition * block + index
        spectrum[index * 2] = tap < taps.count ? taps[tap] : 0
      }
      PartitionedConvolver.transform(
        spectrum, size: size, twiddles: twiddles, reversal: reversal, inverse: false)
    }
  }

  deinit {
    response.deallocate()
    history.deallocate()
    twiddles.deallocate()
    reversal.deallocate()
    sum.deallocate()
    current.deallocate()
    carry.deallocate()
    input.deallocate()
    finished.deallocate()
  }

  /// One frame in, one frame out.
  @_noAllocation
  public mutating func process(_ sample: Float) -> Float {
    let out = current[filled]
    input[filled] = sample
    filled += 1
    if filled == block {
      filled = 0
      finishBlock()
    } else if filled % stride == 0 {
      step(filled / stride)
    }
    return out * gain
  }

  /// The `part`th of the work on the block before this one, 1 to `steps - 1`: its transform first,
  /// then the partitions a share at a time, then the inverse transform.
  @_noAllocation
  private mutating func step(_ part: Int) {
    if part == 1 {
      newest = (newest + partitions - 1) % partitions
      let slot = history + newest * size * 2
      for index in 0..<size {
        slot[index * 2] = index < block ? finished[index] : 0
        slot[index * 2 + 1] = 0
      }
      PartitionedConvolver.transform(slot, size: size, twiddles: twiddles, reversal: reversal, inverse: false)
      for index in 0..<size * 2 { sum[index] = 0 }
    }
    // For the block after next: partition two against the block just finished, three against the
    // one before it, and so on back, in order, as `PartitionedConvolver` sums them.
    let parts = Self.steps - 1
    let first = 2 + (partitions - 2) * (part - 1) / parts
    let last = 2 + (partitions - 2) * part / parts
    for partition in first..<last {
      let past = history + ((newest + partition - 2) % partitions) * size * 2
      let spectrum = response + partition * size * 2
      for bin in 0..<size {
        let i = bin * 2
        sum[i] += past[i] * spectrum[i] - past[i + 1] * spectrum[i + 1]
        sum[i + 1] += past[i] * spectrum[i + 1] + past[i + 1] * spectrum[i]
      }
    }
    if part == parts {
      PartitionedConvolver.transform(sum, size: size, twiddles: twiddles, reversal: reversal, inverse: true)
    }
  }

  /// At the end of a block: the result worked out during it put in place for the next, overlapped
  /// with the one before; and the block kept to be worked on during the next.
  @_noAllocation
  private mutating func finishBlock() {
    let scale = 1 / Float(size)
    for index in 0..<block {
      current[index] = sum[index * 2] * scale + carry[index]
      carry[index] = sum[(index + block) * 2] * scale
      finished[index] = input[index]
    }
  }
}
