import Foundation

/// Error text shared by document and sample operations without linking Android's legacy Foundation.
public enum FailureMessage {
  public static func describe(_ error: any Error) -> String {
    #if os(Android)
      // The Android app links FoundationEssentials. Error.localizedDescription lives in the
      // legacy Foundation overlay; LocalizedError's own message needs no NSError bridge.
      (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    #else
      error.localizedDescription
    #endif
  }
}
