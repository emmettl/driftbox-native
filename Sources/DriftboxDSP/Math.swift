// The only thing this package takes from outside itself: a handful of functions from the
// platform's C library. Everything else in here is +, -, * and / on Doubles, which IEEE 754 makes
// identical everywhere. These are not, quite — see the tolerance in LadderTests — and replacing
// them with implementations of our own is what would make every render bit-exact across platforms.
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#elseif canImport(WASILibc)
  import WASILibc
#else
  // No C library to import — a bare Embedded target. The symbols are still the C ones, and
  // whoever links the result supplies them.
  @_extern(c, "exp") func exp(_ x: Double) -> Double
  @_extern(c, "tanh") func tanh(_ x: Double) -> Double
  @_extern(c, "sin") func sin(_ x: Double) -> Double
  @_extern(c, "cos") func cos(_ x: Double) -> Double
  @_extern(c, "pow") func pow(_ x: Double, _ y: Double) -> Double
  @_extern(c, "log") func log(_ x: Double) -> Double
  @_extern(c, "asin") func asin(_ x: Double) -> Double
#endif

// `@_noAllocation` refuses a call it cannot see into, and a C library is exactly that. These
// are vouched for by hand — each takes doubles and returns one — and this file is the only place
// in the package where that is done. Not inlined, or the call would land back in
// the caller's analysis; against the cost of a `tanh` the extra jump is nothing.
@_semantics("no_performance_analysis") @inline(never)
func dbExp(_ x: Double) -> Double { exp(x) }

@_semantics("no_performance_analysis") @inline(never)
func dbTanh(_ x: Double) -> Double { tanh(x) }

@_semantics("no_performance_analysis") @inline(never)
func dbSin(_ x: Double) -> Double { sin(x) }

@_semantics("no_performance_analysis") @inline(never)
func dbCos(_ x: Double) -> Double { cos(x) }

@_semantics("no_performance_analysis") @inline(never)
func dbAsin(_ x: Double) -> Double { asin(x) }

@_semantics("no_performance_analysis") @inline(never)
func dbLog(_ x: Double) -> Double { log(x) }

@_semantics("no_performance_analysis") @inline(never)
func dbPow(_ x: Double, _ y: Double) -> Double { pow(x, y) }

/// The sine of `turns` whole cycles. Public because an oscillator lives a target away.
public func sin2pi(_ turns: Double) -> Double { dbSin(2 * Double.pi * turns) }

/// The equal-power gains for a pan position, -1 hard left to 1 hard right: the Web Audio
/// `StereoPannerNode`'s law for a mono input.
public func panGains(_ pan: Double) -> (left: Double, right: Double) {
  let x = (max(-1, min(1, pan)) + 1) / 2
  return (dbCos(x * Double.pi / 2), dbSin(x * Double.pi / 2))
}

/// `pow`, for the targets above this one.
public func powDSP(_ base: Double, _ exponent: Double) -> Double { dbPow(base, exponent) }

/// `tanh`, for the targets above this one.
public func tanhDSP(_ x: Double) -> Double { dbTanh(x) }
