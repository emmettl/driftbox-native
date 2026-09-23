#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import WinSDK
#elseif canImport(Android)
  import Android
#elseif canImport(Glibc)
  import Glibc
#endif

/// The machine's monotonic clock, in its own ticks: what MIDI messages are stamped with, so a
/// clock sent out can be placed ahead of time and played at the moment it belongs to.
///
/// The ticks are the platform's — `mach_absolute_time` on the Mac, the performance counter on
/// Windows, nanoseconds elsewhere — because that is what each platform's MIDI stamps against.
/// Nothing outside this reads them as anything but ticks: arithmetic on them goes through here.
public enum HostTime {
  public static func now() -> UInt64 {
    #if canImport(Darwin)
      return mach_absolute_time()
    #elseif os(Windows)
      var count = LARGE_INTEGER()
      QueryPerformanceCounter(&count)
      return UInt64(count.QuadPart)
    #else
      var spec = timespec()
      clock_gettime(CLOCK_MONOTONIC, &spec)
      return UInt64(spec.tv_sec) * 1_000_000_000 + UInt64(spec.tv_nsec)
    #endif
  }

  /// `seconds` after `base`, which may be negative.
  public static func time(_ base: UInt64, after seconds: Double) -> UInt64 {
    guard seconds.isFinite else { return base }
    let ticks = (seconds * ticksPerSecond).rounded()
    if ticks >= 0 { return base &+ UInt64(min(ticks, 1e18)) }
    let back = UInt64(min(-ticks, 1e18))
    return back < base ? base - back : 0
  }

  /// How long it is from `base` to `time`, negative when `time` has been and gone.
  public static func seconds(from base: UInt64, to time: UInt64) -> Double {
    let ahead = time >= base
    let difference = Double(ahead ? time - base : base - time) / ticksPerSecond
    return ahead ? difference : -difference
  }

  /// Now in milliseconds, which is the unit the clock follower is written in.
  public static func milliseconds() -> Double {
    Double(now()) / ticksPerSecond * 1000
  }

  public static let ticksPerSecond: Double = {
    #if canImport(Darwin)
      var info = mach_timebase_info_data_t()
      guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else { return 1e9 }
      return 1e9 * Double(info.denom) / Double(info.numer)
    #elseif os(Windows)
      var frequency = LARGE_INTEGER()
      QueryPerformanceFrequency(&frequency)
      return frequency.QuadPart > 0 ? Double(frequency.QuadPart) : 1e7
    #else
      return 1e9
    #endif
  }()
}
