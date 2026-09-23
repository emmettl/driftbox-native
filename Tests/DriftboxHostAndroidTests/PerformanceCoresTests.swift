import DriftboxHostAndroid
import Testing

/// The choice of cores, from the frequencies a phone reports. The phone's own are measured by
/// `scripts/android-bench.sh`; these are the rule.
struct PerformanceCoresTests {
  @Test func theLittleCoresAreLeftOut() {
    // A Fairphone 6: four little cores, three big and one prime.
    let fairphone = [1_804_800, 1_804_800, 1_804_800, 1_804_800, 2_400_000, 2_400_000, 2_400_000, 2_496_000]
    #expect(PerformanceCores.choose(maximumFrequencies: fairphone) == [4, 5, 6, 7])
  }

  @Test func oneKindOfCoreIsLeftToTheScheduler() {
    #expect(PerformanceCores.choose(maximumFrequencies: [2_000_000, 2_000_000, 2_000_000]).isEmpty)
  }

  @Test func coresThatWillNotSayAreLeftOut() {
    #expect(PerformanceCores.choose(maximumFrequencies: [0, 1_800_000, 0, 2_400_000]) == [3])
    #expect(PerformanceCores.choose(maximumFrequencies: [0, 0]).isEmpty)
    #expect(PerformanceCores.choose(maximumFrequencies: []).isEmpty)
  }

  @Test func theMaskHasABitPerCore() {
    let mask = PerformanceCores.mask([4, 5, 6, 7, 64])
    #expect(mask.count == 16)
    #expect(mask[0] == 0xF0)
    #expect(mask[1] == 1)
    #expect(mask[2...].allSatisfy { $0 == 0 })
  }
}
