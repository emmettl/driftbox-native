/// Convolution for a render thread, with no latency.
///
/// The impulse response is cut into partitions one block long. The first is applied directly,
/// frame by frame, so the response's first tap lands on the frame it should; the rest are
/// transformed once, and every block the spectra of the last `partitions` input blocks are
/// multiplied by them and summed — the same answer as `Convolution.convolve`, a block at a time.
/// Because a block's contribution to the *next* block is known as soon as the block is complete,
/// nothing arrives late.
///
/// A three-second room is 1,100 partitions of 128, which is 280,000 complex multiply-adds per
/// block per channel: a few per cent of a core. Owns raw storage and is not copyable, so
/// `process` is allocation-free.
public struct PartitionedConvolver: ~Copyable {
  public let block: Int
  let size: Int
  public let partitions: Int
  /// Single-precision spectra, `size` complex bins per partition, interleaved real/imaginary.
  let response: UnsafeMutablePointer<Float>
  let history: UnsafeMutablePointer<Float>
  /// Twiddles, bit-reversal table, and scratch for one transform.
  let twiddles: UnsafeMutablePointer<Float>
  let reversal: UnsafeMutablePointer<Int>
  let scratch: UnsafeMutablePointer<Float>
  /// The first partition's taps, and the last `block` inputs, for the direct part.
  let direct: UnsafeMutablePointer<Float>
  let recent: UnsafeMutablePointer<Float>
  var recentIndex = 0
  /// What the transformed partitions contribute to the current block and the one after it.
  let current: UnsafeMutablePointer<Float>
  let carry: UnsafeMutablePointer<Float>
  let input: UnsafeMutablePointer<Float>
  var filled = 0
  var newest = 0
  /// Scaled by this on the way out, as `ConvolverNode` scales.
  public var gain: Float

  public init(response taps: [Float], block: Int = 128, gain: Float = 1) {
    precondition(block > 0 && block & (block - 1) == 0)
    self.block = block
    size = block * 2
    partitions = max(1, (taps.count + block - 1) / block)
    self.gain = gain

    twiddles = .allocate(capacity: size)
    reversal = .allocate(capacity: size)
    scratch = .allocate(capacity: size * 2)
    direct = .allocate(capacity: block)
    recent = .allocate(capacity: block)
    current = .allocate(capacity: block)
    carry = .allocate(capacity: block)
    input = .allocate(capacity: block)
    for index in 0..<block { direct[index] = index < taps.count ? taps[index] : 0 }
    recent.initialize(repeating: 0, count: block)
    current.initialize(repeating: 0, count: block)
    carry.initialize(repeating: 0, count: block)
    input.initialize(repeating: 0, count: block)
    Self.prepare(size: size, twiddles: twiddles, reversal: reversal)

    response = .allocate(capacity: partitions * size * 2)
    history = .allocate(capacity: partitions * size * 2)
    history.initialize(repeating: 0, count: partitions * size * 2)
    for partition in 0..<partitions {
      for index in 0..<size {
        let tap = partition * block + index
        scratch[index * 2] = index < block && tap < taps.count ? taps[tap] : 0
        scratch[index * 2 + 1] = 0
      }
      Self.transform(scratch, size: size, twiddles: twiddles, reversal: reversal, inverse: false)
      (response + partition * size * 2).initialize(from: scratch, count: size * 2)
    }
  }

  deinit {
    response.deallocate()
    history.deallocate()
    twiddles.deallocate()
    reversal.deallocate()
    scratch.deallocate()
    direct.deallocate()
    recent.deallocate()
    current.deallocate()
    carry.deallocate()
    input.deallocate()
  }

  static func prepare(size: Int, twiddles: UnsafeMutablePointer<Float>, reversal: UnsafeMutablePointer<Int>) {
    for k in 0..<size / 2 {
      let angle = -2 * Double.pi * Double(k) / Double(size)
      twiddles[k * 2] = Float(dbCos(angle))
      twiddles[k * 2 + 1] = Float(dbSin(angle))
    }
    var bits = 0
    while 1 << bits < size { bits += 1 }
    for index in 0..<size {
      var reversed = 0
      for bit in 0..<bits where index & (1 << bit) != 0 { reversed |= 1 << (bits - 1 - bit) }
      reversal[index] = reversed
    }
  }

  /// In place, interleaved complex, radix 2. Forward uses the twiddles as they are; inverse
  /// conjugates them and leaves the 1/N to the caller.
  @_noAllocation
  static func transform(
    _ data: UnsafeMutablePointer<Float>, size: Int, twiddles: UnsafePointer<Float>,
    reversal: UnsafePointer<Int>,
    inverse: Bool
  ) {
    for index in 0..<size {
      let target = reversal[index]
      if index < target {
        let real = data[index * 2]
        let imaginary = data[index * 2 + 1]
        data[index * 2] = data[target * 2]
        data[index * 2 + 1] = data[target * 2 + 1]
        data[target * 2] = real
        data[target * 2 + 1] = imaginary
      }
    }
    var length = 2
    while length <= size {
      let half = length / 2
      let step = size / length
      var start = 0
      while start < size {
        for k in 0..<half {
          let wr = twiddles[k * step * 2]
          let wi = inverse ? -twiddles[k * step * 2 + 1] : twiddles[k * step * 2 + 1]
          let a = (start + k) * 2
          let b = (start + k + half) * 2
          let br = data[b] * wr - data[b + 1] * wi
          let bi = data[b] * wi + data[b + 1] * wr
          data[b] = data[a] - br
          data[b + 1] = data[a + 1] - bi
          data[a] += br
          data[a + 1] += bi
        }
        start += length
      }
      length <<= 1
    }
  }

  /// One frame in, one frame out.
  @_noAllocation
  public mutating func process(_ sample: Float) -> Float {
    // The first partition, directly.
    recent[recentIndex] = sample
    var out: Float = 0
    for tap in 0..<block { out += direct[tap] * recent[(recentIndex - tap + block) % block] }
    recentIndex = (recentIndex + 1) % block

    // The rest, worked out at the end of the block before.
    out += current[filled]
    input[filled] = sample
    filled += 1
    if filled == block {
      filled = 0
      renderBlock()
    }
    return out * gain
  }

  @_noAllocation
  private mutating func renderBlock() {
    // Transform the block just finished, zero-padded, into the newest history slot.
    newest = (newest + partitions - 1) % partitions
    let slot = history + newest * size * 2
    for index in 0..<size {
      slot[index * 2] = index < block ? input[index] : 0
      slot[index * 2 + 1] = 0
    }
    Self.transform(slot, size: size, twiddles: twiddles, reversal: reversal, inverse: false)

    // For the block about to start: every partition but the first, against the input block that
    // many blocks before it — the block just finished for partition one, and so on back.
    for index in 0..<size * 2 { scratch[index] = 0 }
    if partitions > 1 {
      for partition in 1..<partitions {
        let past = history + ((newest + partition - 1) % partitions) * size * 2
        let spectrum = response + partition * size * 2
        for bin in 0..<size {
          let i = bin * 2
          scratch[i] += past[i] * spectrum[i] - past[i + 1] * spectrum[i + 1]
          scratch[i + 1] += past[i] * spectrum[i + 1] + past[i + 1] * spectrum[i]
        }
      }
    }
    Self.transform(scratch, size: size, twiddles: twiddles, reversal: reversal, inverse: true)

    // Overlap-add: the first half is for the coming block, the second for the one after.
    let scale = 1 / Float(size)
    for index in 0..<block {
      current[index] = scratch[index * 2] * scale + carry[index]
      carry[index] = scratch[(index + block) * 2] * scale
    }
  }
}
