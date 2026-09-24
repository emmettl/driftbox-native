#if canImport(AVFoundation)
  import DriftboxEngine
  import DriftboxHost
  import DriftboxHostMac
  import DriftboxSeq
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// The tools' own arithmetic, which is the Mac app's rather than the session's.
  @MainActor
  struct ToolsTests {
    @Test func chanceIsARunOfNumbersBetweenNoneAndAll() {
      let random = chance()
      let values = (0..<32).map { _ in random() }
      #expect(values.allSatisfy { $0 >= 0 && $0 < 1 })
      #expect(Set(values).count > 1)
    }
  }
#endif
