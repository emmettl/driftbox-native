import DriftboxGPU
import DriftboxText

/// Every glyph a canvas has drawn, rasterised once by the typesetter and packed into one texture:
/// shelves of glyphs left to right, a new shelf when one is full, a pixel of air around each so
/// that sampling one never reads its neighbour.
///
/// A glyph is kept per quarter of a pixel along, since a glyph a third of a pixel along is not the
/// same bitmap as one on the pixel; four is where the difference stops being visible.
///
/// The texture is written whole — the layer has no smaller update — so the atlas keeps its pixels
/// on the CPU as well, and writes them up only before a draw that needs a glyph it has just added.
final class GlyphAtlas {
  /// Where a glyph is: its texels in the texture, and its bitmap's place relative to the pixel its
  /// origin is in, x right and y down.
  struct Entry {
    var uv: SIMD4<Float>
    var left: Int
    var top: Int
    var width: Int
    var height: Int
  }

  struct Key: Hashable {
    var glyph: Glyph
    var quarter: Int
  }

  let size: Int
  let texture: any GPUTexture
  private var pixels: [UInt8]
  private var entries: [Key: Entry?] = [:]
  private var shelfX = 1
  private var shelfY = 1
  private var shelfHeight = 0
  private(set) var dirty = false

  init(device: any GPUDevice, size: Int = 2048) throws {
    self.size = size
    pixels = [UInt8](repeating: 0, count: size * size * 4)
    texture = try pixels.withUnsafeBytes { try device.makeTexture(width: size, height: size, pixels: $0) }
  }

  /// The glyph at a quarter-pixel `offset`, packing it first if it is new. Nil for a glyph that
  /// covers nothing, and for one too big for the atlas at all; `full` when it would fit an empty
  /// atlas but not this one, which is the caller's cue to draw what it has and `clear`.
  enum Found {
    case entry(Entry)
    case nothing
    case full
  }

  func find(_ glyph: Glyph, quarter: Int, typesetter: any Typesetter) -> Found {
    let key = Key(glyph: glyph, quarter: quarter)
    if let known = entries[key] { return known.map(Found.entry) ?? .nothing }
    guard let coverage = typesetter.coverage(glyph, offset: Float(quarter) / 4) else {
      entries[key] = .some(nil)
      return .nothing
    }
    guard coverage.width + 2 <= size, coverage.height + 2 <= size else {
      entries[key] = .some(nil)
      return .nothing
    }
    if shelfX + coverage.width + 1 > size {
      shelfX = 1
      shelfY += shelfHeight + 1
      shelfHeight = 0
    }
    guard shelfY + coverage.height + 1 <= size else { return .full }

    let x = shelfX
    let y = shelfY
    for row in 0..<coverage.height {
      for column in 0..<coverage.width {
        let value = coverage[column, row]
        let at = ((y + row) * size + x + column) * 4
        // Coverage in every channel: the shader reads alpha, and the rest keep a look at the atlas
        // honest.
        pixels[at] = value
        pixels[at + 1] = value
        pixels[at + 2] = value
        pixels[at + 3] = value
      }
    }
    shelfX += coverage.width + 1
    shelfHeight = max(shelfHeight, coverage.height)
    dirty = true

    let scale = 1 / Float(size)
    let entry = Entry(
      uv: SIMD4(Float(x), Float(y), Float(x + coverage.width), Float(y + coverage.height)) * scale,
      left: coverage.left, top: coverage.top, width: coverage.width, height: coverage.height)
    entries[key] = .some(entry)
    return .entry(entry)
  }

  /// Start again with nothing in it.
  func clear() {
    pixels = [UInt8](repeating: 0, count: size * size * 4)
    entries.removeAll(keepingCapacity: true)
    shelfX = 1
    shelfY = 1
    shelfHeight = 0
    dirty = true
  }

  /// The texture brought up to date, if anything was added since it last was.
  func upload() {
    guard dirty else { return }
    try? pixels.withUnsafeBytes { try texture.update($0) }
    dirty = false
  }
}
