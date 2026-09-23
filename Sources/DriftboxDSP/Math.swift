// The only thing this package takes from outside itself: a handful of functions from the
// platform's C library. Everything else in here is +, -, * and / on Doubles, which IEEE 754 makes
// identical everywhere. These are not, quite — see the tolerance in LadderTests — and replacing
// them with implementations of our own is what would make every render bit-exact across platforms.
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
  // No C library to import — a bare Embedded target. The symbols are still the C ones, and
  // whoever links the result supplies them.
  @_extern(c, "exp") func exp(_ x: Double) -> Double
  @_extern(c, "tanh") func tanh(_ x: Double) -> Double
  @_extern(c, "sin") func sin(_ x: Double) -> Double
  @_extern(c, "cos") func cos(_ x: Double) -> Double
  @_extern(c, "tan") func tan(_ x: Double) -> Double
  @_extern(c, "pow") func pow(_ x: Double, _ y: Double) -> Double
  @_extern(c, "log") func log(_ x: Double) -> Double
  @_extern(c, "asin") func asin(_ x: Double) -> Double
  @_extern(c, "acos") func acos(_ x: Double) -> Double
  @_extern(c, "atan") func atan(_ x: Double) -> Double
  @_extern(c, "atan2") func atan2(_ y: Double, _ x: Double) -> Double
  @_extern(c, "log10") func log10(_ x: Double) -> Double
  @_extern(c, "sinh") func sinh(_ x: Double) -> Double
  @_extern(c, "cosh") func cosh(_ x: Double) -> Double
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
func dbTan(_ x: Double) -> Double { tan(x) }

@_semantics("no_performance_analysis") @inline(never)
func dbAsin(_ x: Double) -> Double { asin(x) }

@_semantics("no_performance_analysis") @inline(never)
func dbLog(_ x: Double) -> Double { log(x) }

@_semantics("no_performance_analysis") @inline(never)
func dbPow(_ x: Double, _ y: Double) -> Double { pow(x, y) }

/// The sine of `turns` whole cycles. Public because an oscillator lives a target away.
@_noAllocation
public func sin2pi(_ turns: Double) -> Double { dbSin(2 * Double.pi * turns) }

/// The equal-power gains for a pan position, -1 hard left to 1 hard right: the Web Audio
/// `StereoPannerNode`'s law for a mono input.
@_noAllocation
public func panGains(_ pan: Double) -> (left: Double, right: Double) {
  let x = (max(-1, min(1, pan)) + 1) / 2
  return (dbCos(x * Double.pi / 2), dbSin(x * Double.pi / 2))
}

/// `pow`, for the targets above this one.
@_noAllocation
public func powDSP(_ base: Double, _ exponent: Double) -> Double { dbPow(base, exponent) }

/// `tanh`, for the targets above this one.
@_noAllocation
public func tanhDSP(_ x: Double) -> Double { dbTanh(x) }

/// `exp`, for the targets above this one.
@_noAllocation
public func expDSP(_ x: Double) -> Double { dbExp(x) }

/// `tan`, for the targets above this one.
@_noAllocation
public func tanDSP(_ x: Double) -> Double { dbTan(x) }

// The rest of JavaScript's `Math` that touches the platform's libm, for the rack's modules. Each is
// the C function of the same name, vouched for by hand as the ones above are.

@_semantics("no_performance_analysis") @inline(never)
func dbAcos(_ x: Double) -> Double { acos(x) }

@_semantics("no_performance_analysis") @inline(never)
func dbAtan(_ x: Double) -> Double { atan(x) }

@_semantics("no_performance_analysis") @inline(never)
func dbAtan2(_ y: Double, _ x: Double) -> Double { atan2(y, x) }

@_semantics("no_performance_analysis") @inline(never)
func dbLog2(_ x: Double) -> Double { log2(x) }

@_semantics("no_performance_analysis") @inline(never)
func dbLog10(_ x: Double) -> Double { log10(x) }

@_semantics("no_performance_analysis") @inline(never)
func dbSinh(_ x: Double) -> Double { sinh(x) }

@_semantics("no_performance_analysis") @inline(never)
func dbCosh(_ x: Double) -> Double { cosh(x) }

@_noAllocation public func sinDSP(_ x: Double) -> Double { dbSin(x) }
@_noAllocation public func cosDSP(_ x: Double) -> Double { dbCos(x) }
@_noAllocation public func logDSP(_ x: Double) -> Double { dbLog(x) }
@_noAllocation public func log2DSP(_ x: Double) -> Double { dbLog2(x) }
@_noAllocation public func log10DSP(_ x: Double) -> Double { dbLog10(x) }
@_noAllocation public func asinDSP(_ x: Double) -> Double { dbAsin(x) }
@_noAllocation public func acosDSP(_ x: Double) -> Double { dbAcos(x) }
@_noAllocation public func atanDSP(_ x: Double) -> Double { dbAtan(x) }
@_noAllocation public func atan2DSP(_ y: Double, _ x: Double) -> Double { dbAtan2(y, x) }
@_noAllocation public func sinhDSP(_ x: Double) -> Double { dbSinh(x) }
@_noAllocation public func coshDSP(_ x: Double) -> Double { dbCosh(x) }

/// `Math.floor`, without the rounding-rule type a render path may not touch. Exact for anything
/// an `Int64` can hold, which is everything a module rounds.
@_noAllocation
public func jsFloor(_ x: Double) -> Double {
  guard x.isFinite, x > -9.2e18, x < 9.2e18 else { return x }
  let truncated = Double(Int64(x))
  return truncated > x ? truncated - 1 : truncated
}

/// `Math.ceil`.
@_noAllocation
public func jsCeil(_ x: Double) -> Double { -jsFloor(-x) }

/// `Math.round`: halves go up, towards positive infinity, as JavaScript's do.
@_noAllocation
public func jsRound(_ x: Double) -> Double { jsFloor(x + 0.5) }

/// `Math.trunc`.
@_noAllocation
public func jsTrunc(_ x: Double) -> Double { x < 0 ? jsCeil(x) : jsFloor(x) }

/// `Math.sqrt`. Exact everywhere — IEEE 754 requires it — but a call the no-allocation check
/// cannot see into in a debug build, so it is vouched for here like the rest.
@_semantics("no_performance_analysis") @inline(never)
func dbSqrt(_ x: Double) -> Double { x.squareRoot() }

@_noAllocation public func sqrtDSP(_ x: Double) -> Double { dbSqrt(x) }
