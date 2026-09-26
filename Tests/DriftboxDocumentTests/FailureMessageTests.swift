import DriftboxDocument
import Foundation
import Testing

struct FailureMessageTests {
  struct NamedFailure: LocalizedError {
    var errorDescription: String? { "Could not load café.wav" }
  }

  @Test func keepsTheErrorsOwnMessage() {
    #expect(FailureMessage.describe(NamedFailure()) == "Could not load café.wav")
  }

  @Test func fileFailuresHaveReadableText() {
    let error = CocoaError(.fileNoSuchFile)
    #expect(!FailureMessage.describe(error).isEmpty)
    #if !os(Android)
      #expect(FailureMessage.describe(error) == error.localizedDescription)
    #endif
  }
}
