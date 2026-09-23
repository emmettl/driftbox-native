// The one thing this target takes from outside itself: `pow`, for pitch and for knobs that move
// in ratios. See the note in DriftboxDSP's Math.swift — the same reasoning, and the same remedy
// if two platforms ever need to agree to the last bit.
#if canImport(Darwin)
  import Darwin
#elseif canImport(Android)
  import Android
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(ucrt)
  import ucrt
#elseif canImport(Musl)
  import Musl
#elseif canImport(WASILibc)
  import WASILibc
#else
  @_extern(c, "pow") func pow(_ x: Double, _ y: Double) -> Double
#endif

@_semantics("no_performance_analysis") @inline(never)
func seqPow(_ x: Double, _ y: Double) -> Double { pow(x, y) }

/// `Math.max(low, Math.min(high, value))`, in that order, as the reference writes it.
@_noAllocation @inline(__always)
func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
  max(low, min(high, value))
}

/// Map a 0...1 knob onto a real range.
@_noAllocation
public func range(_ value: Double, _ low: Double, _ high: Double) -> Double {
  low + (high - low) * clamp(value, 0, 1)
}

/// Map a knob onto a range where equal movement means equal musical change — right for anything
/// in Hz or seconds, where the ear hears ratios.
@_noAllocation
public func ratioRange(_ value: Double, _ low: Double, _ high: Double) -> Double {
  low * seqPow(high / low, clamp(value, 0, 1))
}

/// `((a % n) + n) % n`: where a position falls in a loop, for negative positions too.
@_noAllocation @inline(__always)
func wrap(_ value: Int, _ length: Int) -> Int {
  ((value % length) + length) % length
}
