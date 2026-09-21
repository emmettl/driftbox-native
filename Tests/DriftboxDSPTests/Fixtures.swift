import Foundation

/// `conformance/fixtures`, found from this file's own path so the tests run from a checkout with
/// no bundling step. Written by `conformance/emit/emit.mjs`.
enum Fixtures {
  static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("conformance/fixtures")

  static func data(_ path: String) throws -> Data {
    try Data(contentsOf: root.appendingPathComponent(path))
  }

  /// Little-endian float64, which is also what every machine this runs on already is.
  static func doubles(_ path: String) throws -> [Double] {
    let data = try data(path)
    return data.withUnsafeBytes { raw in
      (0..<raw.count / 8).map { raw.loadUnaligned(fromByteOffset: $0 * 8, as: Double.self) }
    }
  }
}
