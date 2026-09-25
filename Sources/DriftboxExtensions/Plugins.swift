#if canImport(AVFoundation)
  import DriftboxHostMac
  import Foundation

  /// What the extension's owners share: the way to the main actor, where the sessions live, from
  /// whatever thread an app calls on.
  public enum Plugins {
    /// `work` on the main actor, now: in place when already there, and waited for when not.
    nonisolated public static func onMain<T: Sendable>(_ work: @escaping @MainActor () -> T) -> T {
      if Thread.isMainThread { return MainActor.assumeIsolated(work) }
      return DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
    }

    /// How often an owner's timer reads what the app has said: often enough that a note played in
    /// the app is heard within a buffer or two of it.
    static let interval = 0.002
    /// How many of those between one tick of the session and the next: about sixty a second, as
    /// often as a face draws.
    static let sessionEvery = 8
  }

  /// A unit crossing to the main actor, which `AUAudioUnit`, not being `Sendable`, may not on its own.
  public struct Held<Unit: InstrumentAudioUnit>: @unchecked Sendable {
    public let unit: Unit
    public init(unit: Unit) { self.unit = unit }
  }

  /// Whether the app's transport has started or stopped since last asked: a change, which the
  /// instrument follows, and not a state it is held to, so its own Play still plays while the app
  /// stands still.
  struct TransportEdge {
    private var last: Bool?

    mutating func change(_ now: Bool?) -> Bool? {
      guard let now, now != last else { return nil }
      last = now
      return now
    }
  }
#endif
