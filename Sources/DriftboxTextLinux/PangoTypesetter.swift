#if os(Linux)
  import CLinuxUI
  import DriftboxText

  /// Pango shapes fallback-font runs; Cairo rasterizes their glyphs to coverage for the shared canvas.
  /// Use on one thread, as with the GPU canvas that owns its glyph atlas.
  public final class PangoTypesetter: Typesetter {
    private let text: OpaquePointer
    public init() { text = db_text_new()! }
    deinit { db_text_free(text) }

    public func line(_ string: String, font request: FontRequest) -> TextLine {
      guard request.size.isFinite, request.size > 0, request.size <= 4096 else {
        return TextLine(glyphs: [], width: 0, ascent: 0, descent: 0, family: "")
      }
      let families = request.families.isEmpty ? "sans-serif" : request.families.joined(separator: ",")
      let result = db_text_line(text, string, families, Int32(clamping: request.weight), request.size)!
      defer { db_line_free(result) }
      let line = result.pointee
      let glyphs = UnsafeBufferPointer(start: line.glyphs, count: Int(line.count)).map {
        PlacedGlyph(
          glyph: Glyph(face: $0.face, index: $0.index, size: request.size), origin: SIMD2($0.x, $0.y))
      }
      let family = withUnsafePointer(to: &result.pointee.family) {
        $0.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
      }
      return TextLine(
        glyphs: glyphs, width: line.width, ascent: line.ascent, descent: line.descent, family: family)
    }

    public func coverage(_ glyph: Glyph, offset: Float) -> GlyphCoverage? {
      guard offset.isFinite, (0...1).contains(offset),
        let result = db_text_coverage(text, glyph.face, glyph.index, offset)
      else { return nil }
      defer { db_coverage_free(result) }
      let coverage = result.pointee
      return GlyphCoverage(
        width: Int(coverage.width), height: Int(coverage.height),
        left: Int(coverage.left), top: Int(coverage.top),
        bytes: Array(UnsafeBufferPointer(start: coverage.bytes, count: Int(coverage.width * coverage.height)))
      )
    }
  }
#endif
