// The only thing this package takes from outside itself: `exp` and `tanh` from the platform's C
// library. Everything else in here is +, -, * and / on Doubles, which IEEE 754 makes identical
// everywhere. These two are not, quite — see the tolerance in LadderTests — and replacing them
// with implementations of our own is what would make every render bit-exact across platforms.
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#elseif canImport(WASILibc)
  import WASILibc
#else
  // No C library to import — a bare Embedded target. The two symbols are still the C ones, and
  // whoever links the result supplies them.
  @_extern(c, "exp") func exp(_ x: Double) -> Double
  @_extern(c, "tanh") func tanh(_ x: Double) -> Double
#endif

// `@_noAllocation` refuses a call it cannot see into, and a C library is exactly that. These two
// are vouched for by hand — libm's `exp` and `tanh` take a double and return one — and they are
// the only place in the package where that is done. Not inlined, or the call would land back in
// the caller's analysis; against the cost of a `tanh` the extra jump is nothing.
@_semantics("no_performance_analysis") @inline(never)
func dbExp(_ x: Double) -> Double { exp(x) }

@_semantics("no_performance_analysis") @inline(never)
func dbTanh(_ x: Double) -> Double { tanh(x) }
