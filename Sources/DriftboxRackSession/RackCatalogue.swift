import DriftboxDocument
import DriftboxRack
import Foundation

/// What the rack's panels say that the sound does not need — each module's shelf in the
/// picker, its line of copy, its picture and its selectors' words — read from `modules.json`,
/// which the reference's own definitions are exported into. In the picker's order.
public struct ModuleFace: Decodable, Equatable, Sendable {
  public struct Logo: Decodable, Equatable, Sendable {
    public var paths: [String]

    public init(paths: [String]) {
      self.paths = paths
    }
  }

  public var type: String
  public var group: String?
  public var blurb: String?
  public var logo: Logo?
  public var labels: [String: [String]]

  public init(type: String, group: String?, blurb: String?, logo: Logo?, labels: [String: [String]]) {
    self.type = type
    self.group = group
    self.blurb = blurb
    self.logo = logo
    self.labels = labels
  }

  public static let all: [ModuleFace] = {
    guard let url = RackCatalogue.resources?.appending(path: "modules.json"),
      let data = try? Data(contentsOf: url)
    else { return native }
    return ((try? JSONDecoder().decode([ModuleFace].self, from: data)) ?? []) + native
  }()

  /// The modules the reference has none of, so its export has no card for.
  public static let native = [
    ModuleFace(
      type: "plugin", group: "Effects",
      blurb:
        "An Audio Unit effect from this Mac, in stereo, with its own controls a click away. The patch keeps "
        + "which one and how it is set, even where it is missing.",
      logo: Logo(paths: [
        "M14 9v8M24 9v8", "M9 17h20v6a10 10 0 0 1-20 0z", "M19 33v5",
        "M36 23c3-8 6-8 9 0s6 8 9 0",
      ]),
      labels: [:]),
    ModuleFace(
      type: "plugin-instrument", group: "Sources",
      blurb:
        "An Audio Unit instrument from this Mac, played by the rack's notes, every voice of them, with "
        + "mod, bend and sustain. Comes wired to the keys.",
      logo: Logo(paths: [
        "M8 10h48v22H8z", "M16 10v14M24 10v14M40 10v14M48 10v14", "M32 10v22",
      ]),
      labels: [:]),
  ]

  public static let byType: [String: ModuleFace] = Dictionary(
    all.map { ($0.type, $0) }, uniquingKeysWith: { a, _ in a })

  /// The picker's shelves, in the order their first module appears, holding only the modules
  /// this build can make.
  public static var shelves: [(name: String, types: [String])] {
    var order: [String] = []
    var shelves: [String: [String]] = [:]
    for face in all where RackModules.registry[face.type] != nil {
      let group = face.group ?? "Other"
      if shelves[group] == nil { order.append(group) }
      shelves[group, default: []].append(face.type)
    }
    return order.map { ($0, shelves[$0]!) }
  }
}

/// A factory patch, as the picker lists it.
public struct PatchEntry: Decodable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var blurb: String
  public var category: String?
  public var accent: String
  public var play: String?
  public var tip: String?

  public static let all: [PatchEntry] = {
    guard let url = RackCatalogue.resources?.appending(path: "patches.json"),
      let data = try? Data(contentsOf: url)
    else { return [] }
    return (try? JSONDecoder().decode([PatchEntry].self, from: data)) ?? []
  }()

  /// The patch itself, as the reference saved it.
  public func load() -> Patch? {
    guard
      let url = RackCatalogue.resources?.appending(path: "Patches/\(id).patch.json"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return nil }
    return PatchCodec.decode(text)
  }
}

/// Where the rack's catalogue is: its modules' faces, its patches and their list.
public enum RackCatalogue {
  /// This target's resources where SwiftPM builds it, and wherever a platform put them where it
  /// does not. Android's app is built without SwiftPM, and unpacks them from its package, beside
  /// the groovebox's songs, and says where before anything asks for a patch. Read as files, rather
  /// than through `Bundle`, which on Android is the whole of the old Foundation, as
  /// `Catalogue.resources` is for the songs.
  nonisolated(unsafe) public static var resources: URL? = {
    #if SWIFT_PACKAGE
      Bundle.module.resourceURL
    #else
      nil
    #endif
  }()
}
