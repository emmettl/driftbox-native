/// Type, as the rest of Driftbox asks a platform for it: a line of text set in a font, as glyphs
/// placed on a baseline, and each glyph's coverage as a bitmap. Everything else about drawing text —
/// packing glyphs into a texture, placing them through a transform, colouring them — is the same on
/// every platform and is not asked of one.
///
/// A font is asked for the way the web's canvas asks, since that is where every font in Driftbox
/// is named: families in order of preference, a weight, a size in pixels. The platform answers
/// with the first family it has, or with a family of its own when it has none of them.
///
/// Coordinates are the canvas's: x to the right, y down, the origin on the baseline where the line
/// begins.
public protocol Typesetter: AnyObject {
  /// `text` set on one line in the font `request` asks for: shaped, so kerned as the font says, and
  /// never wrapped.
  func line(_ text: String, font request: FontRequest) -> TextLine

  /// What `glyph` covers, drawn with its origin `offset` pixels to the right of a pixel's left edge:
  /// glyphs are placed to fractions of a pixel, and a glyph a third of a pixel along is not the
  /// same bitmap as one on the pixel. Nil for a glyph that covers nothing, such as a space.
  func coverage(_ glyph: Glyph, offset: Float) -> GlyphCoverage?
}

/// A font as the web's canvas names one: `900 48px "Arial Black", Arial`.
public struct FontRequest: Hashable, Sendable {
  /// In order of preference; the first the platform has is the one used.
  public var families: [String]
  /// CSS's weights: 400 is regular, 700 bold, 900 black.
  public var weight: Int
  /// The em, in pixels.
  public var size: Float

  public init(families: [String], weight: Int = 400, size: Float) {
    self.families = families
    self.weight = weight
    self.size = size
  }
}

/// One glyph of one face at one size: what a bitmap of it is cached by. `face` is the typesetter's
/// own number for a face it has set text in, and means nothing to another typesetter.
public struct Glyph: Hashable, Sendable {
  public var face: Int
  public var index: UInt16
  public var size: Float

  public init(face: Int, index: UInt16, size: Float) {
    self.face = face
    self.index = index
    self.size = size
  }
}

/// A glyph placed on a line: its origin, on the baseline, relative to where the line begins.
public struct PlacedGlyph: Hashable, Sendable {
  public var glyph: Glyph
  public var origin: SIMD2<Float>

  public init(glyph: Glyph, origin: SIMD2<Float>) {
    self.glyph = glyph
    self.origin = origin
  }
}

/// A line of text, set.
public struct TextLine: Sendable {
  public var glyphs: [PlacedGlyph]
  /// How far the pen moved: the canvas's `measureText(text).width`, trailing spaces included.
  public var width: Float
  /// The font's own extent above and below the baseline, in pixels, both positive.
  public var ascent: Float
  public var descent: Float
  /// The family that was used, which is one of those asked for or the platform's own fallback.
  public var family: String

  public init(glyphs: [PlacedGlyph], width: Float, ascent: Float, descent: Float, family: String) {
    self.glyphs = glyphs
    self.width = width
    self.ascent = ascent
    self.descent = descent
    self.family = family
  }
}

/// A glyph's coverage: one byte per pixel, 0 untouched to 255 covered, rows from the top.
public struct GlyphCoverage: Sendable {
  public var width: Int
  public var height: Int
  /// Where the bitmap's top-left pixel is, relative to the pixel the glyph's origin is in: x to the
  /// right, y down, so a letter standing on the baseline has a negative `top`.
  public var left: Int
  public var top: Int
  public var bytes: [UInt8]

  public init(width: Int, height: Int, left: Int, top: Int, bytes: [UInt8]) {
    self.width = width
    self.height = height
    self.left = left
    self.top = top
    self.bytes = bytes
  }

  public subscript(x: Int, y: Int) -> UInt8 { bytes[y * width + x] }
}

/// A typesetter that sets nothing: for a platform that has none of its own yet, where type is
/// simply not drawn — every line is empty and no glyph covers anything.
public final class NoTypesetter: Typesetter {
  public init() {}

  public func line(_ text: String, font request: FontRequest) -> TextLine {
    TextLine(glyphs: [], width: 0, ascent: 0, descent: 0, family: "")
  }

  public func coverage(_ glyph: Glyph, offset: Float) -> GlyphCoverage? { nil }
}
