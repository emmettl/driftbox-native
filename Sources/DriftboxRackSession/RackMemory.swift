import Foundation

/// Where a rack keeps what it remembers between launches: its patch, and the controllers learnt
/// onto its knobs. `UserDefaults` on the Mac and Windows; on Android, where `UserDefaults` is the
/// old Foundation's and brings its 48MB of internationalisation with it, whatever the app keeps
/// instead. As `SessionMemory` is for the groovebox.
public protocol RackMemory: AnyObject {
  func string(forKey key: String) -> String?
  func set(_ value: Any?, forKey key: String)
}

#if !os(Android)
  extension UserDefaults: RackMemory {}
#endif
