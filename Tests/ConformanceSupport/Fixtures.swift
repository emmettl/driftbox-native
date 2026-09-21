import Foundation

/// `conformance/fixtures`, found from this file's own path so the tests run from a checkout with
/// no bundling step. Written by `conformance/emit/emit.mjs`.
public enum Fixtures {
  public static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("conformance/fixtures")

  public static func data(_ path: String) throws -> Data {
    try Data(contentsOf: root.appendingPathComponent(path))
  }

  public static func text(_ path: String) throws -> String {
    String(decoding: try data(path), as: UTF8.self)
  }

  /// Little-endian float64, which is also what every machine this runs on already is.
  public static func doubles(_ path: String) throws -> [Double] {
    let data = try data(path)
    return data.withUnsafeBytes { raw in
      (0..<raw.count / 8).map { raw.loadUnaligned(fromByteOffset: $0 * 8, as: Double.self) }
    }
  }

  /// The ids of the catalogue songs, in catalogue order.
  public static func songIds() throws -> [String] {
    struct Catalogue: Decodable {
      struct Entry: Decodable { let id: String }
      let songs: [Entry]
    }
    return try JSONDecoder().decode(Catalogue.self, from: data("catalogue.json")).songs.map(\.id)
  }
}
