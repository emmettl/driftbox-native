/// A long convolution for a render thread, in two stages: the head of the response in partitions
/// one block long, applied with no latency; the tail in partitions eight blocks long, which cost
/// an eighth as much per frame and are just as much on time — a partition that starts sixteen
/// blocks in is not due for sixteen blocks. The same answer as one `PartitionedConvolver` over the
/// whole response, at about a quarter of the cost on a three-second room.
///
/// The head is two of the tail's blocks long, so that the tail's work on a block need not be done
/// until a block later, and is spread over that block by `SpreadConvolver` rather than done in the
/// one render callback the block ends in.
public struct Reverb: ~Copyable {
  /// How many of the head's blocks one of the tail's is.
  public static var tailBlock: Int { 8 }
  var head: PartitionedConvolver
  var tail: SpreadConvolver?

  public init(response taps: [Float], block: Int = 128, gain: Float = 1) {
    let tailBlock = block * Self.tailBlock
    let split = tailBlock * 2
    head = PartitionedConvolver(response: Array(taps.prefix(split)), block: block, gain: gain)
    if taps.count > split {
      // The tail's first two partitions are empty, so that its third starts where the head ends.
      let padded = [Float](repeating: 0, count: split) + taps[split...]
      tail = SpreadConvolver(response: padded, block: tailBlock, gain: gain)
    }
  }

  @_noAllocation
  public mutating func process(_ sample: Float) -> Float {
    var out = head.process(sample)
    if tail != nil { out += tail!.process(sample) }
    return out
  }
}
