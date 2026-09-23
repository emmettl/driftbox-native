/// Which cores a render thread is kept to on a phone: every core but the slowest kind.
///
/// Measured, not assumed: on a Fairphone 6 a little core renders the engine at 69% of real time
/// flat out and falls behind altogether when paced, while a big one takes 16%. The scheduler does
/// not know which thread is the one that must not fall behind, so the thread says. A phone with
/// only one kind of core, or one that will not say how fast its cores go, is left to the scheduler.
///
/// Platform-neutral arithmetic, so that it is tested wherever the package builds; only the reading
/// of the frequencies is Android's.
public enum PerformanceCores {
  /// The cores to keep to, by number, from each core's highest frequency, in core order. Empty for
  /// "any": the scheduler's choice is left alone.
  public static func choose(maximumFrequencies: [Int]) -> [Int] {
    let known = maximumFrequencies.enumerated().filter { $0.element > 0 }
    guard let slowest = known.map(\.element).min(), known.contains(where: { $0.element > slowest }) else {
      return []
    }
    return known.filter { $0.element > slowest }.map(\.offset)
  }

  /// `cores` as the words of a Linux CPU set, lowest core in the lowest bit of the first word,
  /// which is what `sched_setaffinity` takes.
  public static func mask(_ cores: [Int], words: Int = 16) -> [UInt64] {
    var mask = [UInt64](repeating: 0, count: words)
    for core in cores where core >= 0 && core < words * 64 {
      mask[core / 64] |= 1 << UInt64(core % 64)
    }
    return mask
  }
}
