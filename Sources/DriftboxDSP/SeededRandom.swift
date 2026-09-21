/// The engine's one noise generator: xorshift32, as `seededRandom` in
/// `driftbox/packages/engine/src/render.ts`. The reverb's impulse response and every noise
/// source draw from it, so a render is a function of the song and nothing else.
public struct SeededRandom {
  var state: UInt32

  /// A seed of zero would stick at zero for ever, so it becomes one — as the reference does.
  public init(seed: UInt32) {
    state = seed == 0 ? 1 : seed
  }

  /// The raw 32 bits. `next()` is this over 2^32.
  @_noAllocation
  public mutating func nextBits() -> UInt32 {
    state ^= state << 13
    state ^= state >> 17
    state ^= state << 5
    return state
  }

  /// 0..<1.
  @_noAllocation
  public mutating func next() -> Double {
    Double(nextBits()) / 4_294_967_296
  }
}
