/// A long convolution for a render thread, in two stages: the head of the response in partitions
/// one block long, applied with no latency; the tail in partitions eight blocks long, which cost
/// an eighth as much per frame and are just as much on time — a partition that starts eight
/// blocks in is not due for eight blocks. The same answer as one `PartitionedConvolver` over the
/// whole response, at about a quarter of the cost on a three-second room.
public struct Reverb: ~Copyable {
  public static var headBlocks: Int { 8 }
  var head: PartitionedConvolver
  var tail: PartitionedConvolver?

  public init(response taps: [Float], block: Int = 128, gain: Float = 1) {
    let split = block * Self.headBlocks
    head = PartitionedConvolver(response: Array(taps.prefix(split)), block: block, gain: gain)
    if taps.count > split {
      // The tail's first partition is empty, so that its second starts where the head ends.
      let padded = [Float](repeating: 0, count: split) + taps[split...]
      tail = PartitionedConvolver(response: padded, block: split, gain: gain)
    }
  }

  @_noAllocation
  public mutating func process(_ sample: Float) -> Float {
    var out = head.process(sample)
    if tail != nil { out += tail!.process(sample) }
    return out
  }
}
