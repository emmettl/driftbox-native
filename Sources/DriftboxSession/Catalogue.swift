import DriftboxDocument
import DriftboxSeq
import Foundation

/// A song the app ships with, or one opened from a file and named for it.
public struct CatalogueEntry: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let blurb: String
  public let visual: String

  public init(id: String, name: String, blurb: String, visual: String) {
    self.id = id
    self.name = name
    self.blurb = blurb
    self.visual = visual
  }
}

/// The catalogue that ships with the app, on every platform: the same documents the conformance
/// fixtures hold, in this target's resources.
public enum Catalogue {
  public static func entries() -> [CatalogueEntry] {
    struct File: Decodable {
      struct Entry: Decodable {
        let id: String
        let name: String
        let blurb: String
        let visual: String
      }
      let songs: [Entry]
    }
    guard let url = Bundle.module.url(forResource: "catalogue", withExtension: "json"),
      let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data)
    else { return [] }
    return file.songs.map { CatalogueEntry(id: $0.id, name: $0.name, blurb: $0.blurb, visual: $0.visual) }
  }

  /// Where the song `id` is, for a platform whose app wants the file itself.
  public static func url(of id: String) -> URL? {
    Bundle.module.url(forResource: id, withExtension: "song.json", subdirectory: "Songs")
  }

  public static func song(_ id: String) -> Song? {
    guard let url = url(of: id), let data = try? Data(contentsOf: url) else { return nil }
    return SongCodec.decode(String(decoding: data, as: UTF8.self))
  }
}
