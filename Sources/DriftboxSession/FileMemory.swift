import Foundation

/// What an app remembers between launches, kept in a file of its own: for a platform whose
/// `UserDefaults` is not to be had, as Android's is the old Foundation's and not linked. Strings,
/// true or false, and data — which is all a session or a rack keeps — as JSON, the whole of it
/// written again after every change, which is a few hundred bytes and a rack's patch. Anything
/// else set is not kept. A file that is not there, or cannot be read, is nothing remembered.
public final class FileMemory: SessionMemory {
  private struct Stored: Codable, Equatable {
    var strings: [String: String] = [:]
    var flags: [String: Bool] = [:]
    var data: [String: Data] = [:]
  }

  public let url: URL
  private var stored: Stored

  public init(url: URL) {
    self.url = url
    let read = try? Data(contentsOf: url)
    stored = read.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
  }

  public func object(forKey key: String) -> Any? {
    if let string = stored.strings[key] { return string }
    if let flag = stored.flags[key] { return flag }
    return stored.data[key]
  }

  public func string(forKey key: String) -> String? { stored.strings[key] }
  public func bool(forKey key: String) -> Bool { stored.flags[key] ?? false }
  public func data(forKey key: String) -> Data? { stored.data[key] }

  public func set(_ value: Any?, forKey key: String) {
    var next = stored
    Self.remove(key, from: &next)
    switch value {
    case let flag as Bool: next.flags[key] = flag
    case let string as String: next.strings[key] = string
    case let data as Data: next.data[key] = data
    default: break
    }
    save(next)
  }

  public func removeObject(forKey key: String) {
    var next = stored
    Self.remove(key, from: &next)
    save(next)
  }

  private static func remove(_ key: String, from stored: inout Stored) {
    stored.strings[key] = nil
    stored.flags[key] = nil
    stored.data[key] = nil
  }

  /// Written only when something changed, whole and at once, so a launch that dies halfway through
  /// writing leaves the last whole file.
  private func save(_ next: Stored) {
    guard next != stored else { return }
    stored = next
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(stored) else { return }
    try? data.write(to: url, options: .atomic)
  }
}
