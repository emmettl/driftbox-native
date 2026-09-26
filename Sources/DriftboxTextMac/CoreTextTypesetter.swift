#if canImport(CoreText)
  import CoreGraphics
  import CoreText
  import DriftboxText
  import Foundation

  /// Type on the Mac: Core Text, which sets a line as a `CTLine` — shaped, so kerned from the font's
  /// own tables as a browser's canvas kerns it — and draws a glyph into a grey bitmap of our own.
  ///
  /// Coverage is antialiased and nothing more: no font smoothing, which thickens stems for a
  /// screen's text and would make the Mac's type heavier than every other platform's, and glyphs
  /// placed to any fraction of a pixel, as a canvas places them.
  public final class CoreTextTypesetter: Typesetter {
    /// A font per font asked for, made once, with the family it settled on.
    private var fonts: [FontRequest: (font: CTFont, family: String)] = [:]
    /// Every face a line has been set in, numbered for `Glyph.face`, at whatever size it was first
    /// seen: a glyph's own size is in the glyph.
    private var faces: [CTFont] = []
    private var faceNumbers: [String: Int] = [:]
    /// The families installed, looked up once.
    private lazy var installed: Set<String> = Set(
      (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? [])

    /// The family used when none of those asked for is installed: every Mac has it.
    public static let fallback = "Helvetica"

    public init() {}

    public func line(_ text: String, font request: FontRequest) -> TextLine {
      let (font, family) = font(for: request)
      let attributed = CFAttributedStringCreate(
        nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary)
      guard let attributed else {
        return TextLine(glyphs: [], width: 0, ascent: 0, descent: 0, family: family)
      }
      let line = CTLineCreateWithAttributedString(attributed)
      var glyphs: [PlacedGlyph] = []
      // The extents are the font's own, from whichever face the line was set in first: the one
      // asked for, or one Core Text fell back to for a character it has none of.
      var lineFont = font
      for (runIndex, run) in ((CTLineGetGlyphRuns(line) as? [CTRun]) ?? []).enumerated() {
        let count = CTRunGetGlyphCount(run)
        guard count > 0 else { continue }
        let attributes = CTRunGetAttributes(run) as NSDictionary
        let runFont = attributes[kCTFontAttributeName] as! CTFont? ?? font
        if runIndex == 0 { lineFont = runFont }
        let face = number(for: runFont)
        var indices = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &indices)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        let size = Float(CTFontGetSize(runFont))
        for (index, position) in zip(indices, positions) {
          glyphs.append(
            PlacedGlyph(
              glyph: Glyph(face: face, index: index, size: size),
              // Core Text's y is up; the line's is down.
              origin: SIMD2(Float(position.x), -Float(position.y))))
        }
      }
      // The typographic width is how far the pen went, trailing spaces included, as
      // `measureText` measures.
      let width = CTLineGetTypographicBounds(line, nil, nil, nil)
      return TextLine(
        glyphs: glyphs, width: Float(width), ascent: Float(CTFontGetAscent(lineFont)),
        descent: Float(CTFontGetDescent(lineFont)), family: family)
    }

    public func coverage(_ glyph: Glyph, offset: Float) -> GlyphCoverage? {
      guard glyph.face >= 0, glyph.face < faces.count else { return nil }
      let font = CTFontCreateCopyWithAttributes(faces[glyph.face], CGFloat(glyph.size), nil, nil)
      var index = CGGlyph(glyph.index)
      var bounds = CGRect.zero
      CTFontGetBoundingRectsForGlyphs(font, .horizontal, &index, &bounds, 1)
      guard !bounds.isEmpty, bounds.width > 0, bounds.height > 0 else { return nil }

      // The bitmap: the glyph's bounds from where its origin is, out to whole pixels and a pixel
      // more each way, for the antialiasing at its edges. `top` is down from the origin's pixel.
      let along = CGFloat(offset)
      let left = Int((along + bounds.minX).rounded(.down)) - 1
      let right = Int((along + bounds.maxX).rounded(.up)) + 1
      let top = -Int(bounds.maxY.rounded(.up)) - 1
      let bottom = -Int(bounds.minY.rounded(.down)) + 1
      let width = right - left
      let height = bottom - top
      guard width > 0, height > 0,
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return nil }
      context.setShouldAntialias(true)
      context.setShouldSmoothFonts(false)
      context.setAllowsFontSubpixelPositioning(true)
      context.setShouldSubpixelPositionFonts(true)
      context.setAllowsFontSubpixelQuantization(false)
      context.setShouldSubpixelQuantizeFonts(false)
      context.setFillColor(gray: 0, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.setFillColor(gray: 1, alpha: 1)
      // The bitmap's y is up from its bottom row, where the baseline is `height + top` rows up.
      var origin = CGPoint(x: along - CGFloat(left), y: CGFloat(height + top))
      CTFontDrawGlyphs(font, &index, &origin, 1, context)
      guard let data = context.data else { return nil }
      // The context's rows are from the top, as coverage's are.
      let bytes = Array(
        UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height))
      guard bytes.contains(where: { $0 != 0 }) else { return nil }
      return GlyphCoverage(width: width, height: height, left: left, top: top, bytes: bytes)
    }

    /// The font for a request: the first of its families that is installed, in the face of it
    /// nearest the weight asked for, at its size.
    private func font(for request: FontRequest) -> (CTFont, String) {
      if let known = fonts[request] { return known }
      let family = request.families.first { installed.contains($0) } ?? Self.fallback
      let font = Self.face(of: family, weight: request.weight, size: CGFloat(request.size))
      fonts[request] = (font, family)
      return (font, family)
    }

    /// The upright face of `family` whose weight is nearest `weight`, CSS's 100 to 900: Arial Black
    /// is a family of its own, so 900 in Arial is Arial's boldest, as a browser would have it.
    static func face(of family: String, weight: Int, size: CGFloat) -> CTFont {
      let wanted = coreTextWeight(weight)
      let familyOnly = CTFontDescriptorCreateWithAttributes(
        [kCTFontFamilyNameAttribute: family] as CFDictionary)
      let faces =
        (CTFontDescriptorCreateMatchingFontDescriptors(familyOnly, nil) as? [CTFontDescriptor]) ?? []
      func traits(_ face: CTFontDescriptor) -> (weight: Double, width: Double, italic: Bool) {
        let traits = CTFontDescriptorCopyAttribute(face, kCTFontTraitsAttribute) as? [CFString: Any] ?? [:]
        let symbolic = (traits[kCTFontSymbolicTrait] as? UInt32) ?? 0
        return (
          (traits[kCTFontWeightTrait] as? Double) ?? 0, (traits[kCTFontWidthTrait] as? Double) ?? 0,
          symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0
        )
      }
      let best = faces.min { a, b in
        func distance(_ face: CTFontDescriptor) -> Double {
          let (weight, width, italic) = traits(face)
          return abs(weight - wanted) + abs(width) * 2 + (italic ? 10 : 0)
        }
        return distance(a) < distance(b)
      }
      return CTFontCreateWithFontDescriptor(best ?? familyOnly, size, nil)
    }

    /// CSS's weights on Core Text's scale, -1 to 1, where 400 is 0: the points `NSFont.Weight`
    /// gives, and a straight line between them.
    static func coreTextWeight(_ weight: Int) -> Double {
      let points: [(css: Double, coreText: Double)] = [
        (100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23), (600, 0.3), (700, 0.4), (800, 0.56),
        (900, 0.62),
      ]
      let css = min(900, max(100, Double(weight)))
      for (low, high) in zip(points, points.dropFirst()) where css <= high.css {
        let along = (css - low.css) / (high.css - low.css)
        return low.coreText + (high.coreText - low.coreText) * along
      }
      return points.last!.coreText
    }

    /// The number for a face, kept the first time it is seen.
    private func number(for font: CTFont) -> Int {
      let name = CTFontCopyPostScriptName(font) as String
      if let known = faceNumbers[name] { return known }
      faces.append(font)
      faceNumbers[name] = faces.count - 1
      return faces.count - 1
    }
  }
#endif
