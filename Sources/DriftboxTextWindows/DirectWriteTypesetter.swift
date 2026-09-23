#if os(Windows)
  import CDirectWrite
  import DriftboxText
  import WinSDK

  /// Type on Windows: DirectWrite, which sets a line with its own text layout — shaped, so kerned
  /// from the font's own tables as a browser's canvas kerns it — and rasterises a glyph with a glyph
  /// run analysis. The layout is drawn through a text renderer of our own, which is how DirectWrite
  /// hands back the glyphs it placed; that renderer is a COM object built by hand, as
  /// `DriftboxHostWindows` builds its device notifications.
  ///
  /// Coverage is DirectWrite's natural, symmetric rendering: antialiased across and down, as a
  /// browser antialiases canvas text. DirectWrite hands that back as three samples a pixel, for
  /// ClearType, and they are averaged to one here — grey coverage, since what is drawn from it is
  /// about to be placed through a transform and would carry colour fringes with it otherwise.
  public final class DirectWriteTypesetter: Typesetter {
    private let factory: UnsafeMutablePointer<IDWriteFactory>
    private let collection: UnsafeMutablePointer<IDWriteFontCollection>
    /// A format per font asked for, made once, with the family it settled on.
    private var formats: [FontRequest: (format: UnsafeMutablePointer<IDWriteTextFormat>, family: String)] =
      [:]
    /// Every face a line has been set in, each retained, and numbered for `Glyph.face`.
    private var faces: [UnsafeMutablePointer<IDWriteFontFace>] = []
    private var faceNumbers: [UnsafeMutableRawPointer: Int] = [:]

    /// The family used when none of those asked for is installed: every Windows since Vista has it.
    public static let fallback = "Segoe UI"

    public init() throws {
      var iid = DirectWrite.iidFactory
      var unknown: UnsafeMutablePointer<IUnknown>?
      let made = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &iid, &unknown)
      guard made >= 0, let unknown else { throw DirectWrite.Failure("no DirectWrite factory", made) }
      factory = UnsafeMutableRawPointer(unknown).assumingMemoryBound(to: IDWriteFactory.self)
      var collection: UnsafeMutablePointer<IDWriteFontCollection>?
      let found = factory.pointee.lpVtbl.pointee.GetSystemFontCollection(factory, &collection, false)
      guard found >= 0, let collection else {
        _ = factory.pointee.lpVtbl.pointee.Release(factory)
        throw DirectWrite.Failure("no system fonts", found)
      }
      self.collection = collection
    }

    deinit {
      for face in faces { _ = face.pointee.lpVtbl.pointee.Release(face) }
      for (format, _) in formats.values { _ = format.pointee.lpVtbl.pointee.Release(format) }
      _ = collection.pointee.lpVtbl.pointee.Release(collection)
      _ = factory.pointee.lpVtbl.pointee.Release(factory)
    }

    public func line(_ text: String, font request: FontRequest) -> TextLine {
      guard let (format, family) = format(for: request) else {
        return TextLine(glyphs: [], width: 0, ascent: 0, descent: 0, family: Self.fallback)
      }
      let utf16 = Array(text.utf16)
      var layout: UnsafeMutablePointer<IDWriteTextLayout>?
      let laid = utf16.withUnsafeBufferPointer { characters in
        factory.pointee.lpVtbl.pointee.CreateTextLayout(
          factory, characters.baseAddress, UInt32(characters.count), format, 1_000_000, 1_000_000, &layout)
      }
      guard laid >= 0, let layout else {
        return TextLine(glyphs: [], width: 0, ascent: 0, descent: 0, family: family)
      }
      defer { _ = layout.pointee.lpVtbl.pointee.Release(layout) }

      let collector = Collector(typesetter: self)
      _ = withExtendedLifetime(collector) {
        layout.pointee.lpVtbl.pointee.Draw(
          layout, Unmanaged.passUnretained(collector).toOpaque(), Renderer.shared, 0, 0)
      }
      var metrics = DWRITE_TEXT_METRICS()
      _ = layout.pointee.lpVtbl.pointee.GetMetrics(layout, &metrics)

      // The extents are the font's own, from whichever face the line was set in — or, for a line
      // with nothing in it, the face the format would have used, which is not to hand; zero then.
      var ascent: Float = 0
      var descent: Float = 0
      if let first = collector.glyphs.first {
        var font = DWRITE_FONT_METRICS()
        let face = faces[first.glyph.face]
        face.pointee.lpVtbl.pointee.GetMetrics(face, &font)
        let scale = request.size / Float(max(1, font.designUnitsPerEm))
        ascent = Float(font.ascent) * scale
        descent = Float(font.descent) * scale
      }
      return TextLine(
        glyphs: collector.glyphs, width: metrics.widthIncludingTrailingWhitespace, ascent: ascent,
        descent: descent, family: family)
    }

    public func coverage(_ glyph: Glyph, offset: Float) -> GlyphCoverage? {
      guard glyph.face >= 0, glyph.face < faces.count else { return nil }
      var index = glyph.index
      var advance: Float = 0
      var analysis: UnsafeMutablePointer<IDWriteGlyphRunAnalysis>?
      let analysed = withUnsafePointer(to: &index) { indices in
        withUnsafePointer(to: &advance) { advances in
          var run = DWRITE_GLYPH_RUN(
            fontFace: faces[glyph.face], fontEmSize: glyph.size, glyphCount: 1, glyphIndices: indices,
            glyphAdvances: advances, glyphOffsets: nil, isSideways: false, bidiLevel: 0)
          return factory.pointee.lpVtbl.pointee.CreateGlyphRunAnalysis(
            factory, &run, 1, nil, DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
            Int32(CDIRECTWRITE_MEASURING_NATURAL),
            offset, 0, &analysis)
        }
      }
      guard analysed >= 0, let analysis else { return nil }
      defer { _ = analysis.pointee.lpVtbl.pointee.Release(analysis) }

      var bounds = RECT()
      _ = analysis.pointee.lpVtbl.pointee.GetAlphaTextureBounds(
        analysis, DWRITE_TEXTURE_CLEARTYPE_3x1, &bounds)
      let width = Int(bounds.right - bounds.left)
      let height = Int(bounds.bottom - bounds.top)
      guard width > 0, height > 0 else { return nil }
      var samples = [UInt8](repeating: 0, count: width * height * 3)
      let drawn = samples.withUnsafeMutableBufferPointer { out in
        analysis.pointee.lpVtbl.pointee.CreateAlphaTexture(
          analysis, DWRITE_TEXTURE_CLEARTYPE_3x1, &bounds, out.baseAddress, UInt32(out.count))
      }
      guard drawn >= 0 else { return nil }
      var bytes = [UInt8](repeating: 0, count: width * height)
      for pixel in 0..<(width * height) {
        let sum = Int(samples[pixel * 3]) + Int(samples[pixel * 3 + 1]) + Int(samples[pixel * 3 + 2])
        bytes[pixel] = UInt8((sum + 1) / 3)
      }
      return GlyphCoverage(
        width: width, height: height, left: Int(bounds.left), top: Int(bounds.top), bytes: bytes)
    }

    /// The text format for a font: the first of its families that is installed, at its weight and
    /// size, never wrapping.
    private func format(for request: FontRequest) -> (UnsafeMutablePointer<IDWriteTextFormat>, String)? {
      if let known = formats[request] { return known }
      let family =
        request.families.first { name in
          var index: UInt32 = 0
          var exists: WindowsBool = false
          let asked = DirectWrite.wide(name) {
            collection.pointee.lpVtbl.pointee.FindFamilyName(collection, $0, &index, &exists)
          }
          return asked >= 0 && exists.boolValue
        } ?? Self.fallback
      var format: UnsafeMutablePointer<IDWriteTextFormat>?
      let made = DirectWrite.wide(family) { name in
        DirectWrite.wide("en-us") { locale in
          factory.pointee.lpVtbl.pointee.CreateTextFormat(
            factory, name, collection, Int32(request.weight), DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL, request.size, locale, &format)
        }
      }
      guard made >= 0, let format else { return nil }
      _ = format.pointee.lpVtbl.pointee.SetWordWrapping(format, DWRITE_WORD_WRAPPING_NO_WRAP)
      formats[request] = (format, family)
      return (format, family)
    }

    /// The number for a face, retaining it the first time it is seen.
    fileprivate func number(for face: UnsafeMutablePointer<IDWriteFontFace>) -> Int {
      if let known = faceNumbers[UnsafeMutableRawPointer(face)] { return known }
      _ = face.pointee.lpVtbl.pointee.AddRef(face)
      faces.append(face)
      faceNumbers[UnsafeMutableRawPointer(face)] = faces.count - 1
      return faces.count - 1
    }
  }

  /// What one line's layout draws, gathered as it draws it.
  private final class Collector {
    unowned let typesetter: DirectWriteTypesetter
    var glyphs: [PlacedGlyph] = []

    init(typesetter: DirectWriteTypesetter) { self.typesetter = typesetter }

    /// One run of glyphs in one face: each at the pen, moved by its offset, the pen then moved on
    /// by its advance. The baseline is the run's, and every run of one line shares it.
    func add(_ run: DWRITE_GLYPH_RUN, baseline: SIMD2<Float>) {
      let face = typesetter.number(for: run.fontFace)
      var pen = baseline.x
      for index in 0..<Int(run.glyphCount) {
        let offset = run.glyphOffsets?[index] ?? DWRITE_GLYPH_OFFSET(advanceOffset: 0, ascenderOffset: 0)
        glyphs.append(
          PlacedGlyph(
            glyph: Glyph(face: face, index: run.glyphIndices[index], size: run.fontEmSize),
            origin: SIMD2(pen + offset.advanceOffset, -offset.ascenderOffset)))
        pen += run.glyphAdvances?[index] ?? 0
      }
    }
  }

  /// The text renderer every layout is drawn through. It has no state of its own — each draw hands
  /// it the line's collector as DirectWrite's per-draw context — so one serves every typesetter.
  private enum Renderer {
    /// Made once and never written again, so shared between threads without harm.
    nonisolated(unsafe) static let shared: UnsafeMutablePointer<IDWriteTextRenderer> = {
      let vtable = UnsafeMutablePointer<IDWriteTextRendererVtbl>.allocate(capacity: 1)
      vtable.initialize(
        to: IDWriteTextRendererVtbl(
          QueryInterface: { this, iid, out in
            guard let out else { return HRESULT(bitPattern: 0x8000_4003) }  // E_POINTER
            if DirectWrite.equal(iid, DirectWrite.iidUnknown)
              || DirectWrite.equal(iid, DirectWrite.iidPixelSnapping)
              || DirectWrite.equal(iid, DirectWrite.iidTextRenderer)
            {
              out.pointee = UnsafeMutableRawPointer(this)
              return S_OK
            }
            out.pointee = nil
            return HRESULT(bitPattern: 0x8000_4002)  // E_NOINTERFACE
          },
          // It lives as long as the process: nothing COM does to its count matters.
          AddRef: { _ in 1 },
          Release: { _ in 1 },
          // Unsnapped: glyphs where the font puts them, to fractions of a pixel, as a canvas does.
          IsPixelSnappingDisabled: { _, _, disabled in
            disabled?.pointee = true
            return S_OK
          },
          GetCurrentTransform: { _, _, transform in
            transform?.pointee = DWRITE_MATRIX(m11: 1, m12: 0, m21: 0, m22: 1, dx: 0, dy: 0)
            return S_OK
          },
          GetPixelsPerDip: { _, _, pixels in
            pixels?.pointee = 1
            return S_OK
          },
          DrawGlyphRun: { _, context, x, y, _, run, _, _ in
            guard let context, let run else { return S_OK }
            Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue().add(
              run.pointee, baseline: SIMD2(x, y))
            return S_OK
          },
          DrawUnderline: { _, _, _, _, _, _ in S_OK },
          DrawStrikethrough: { _, _, _, _, _, _ in S_OK },
          DrawInlineObject: { _, _, _, _, _, _, _, _ in S_OK }))
      let renderer = UnsafeMutablePointer<IDWriteTextRenderer>.allocate(capacity: 1)
      renderer.initialize(to: IDWriteTextRenderer(lpVtbl: vtable))
      return renderer
    }()
  }

  enum DirectWrite {
    struct Failure: Error, CustomStringConvertible {
      let description: String
      init(_ what: String, _ result: HRESULT) {
        description = "\(what): 0x\(String(UInt32(bitPattern: result), radix: 16))"
      }
    }

    static let iidUnknown = guid(
      0x0000_0000, 0x0000, 0x0000, (0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46))
    static let iidFactory = guid(
      0xb859_ee5a, 0xd838, 0x4b5b, (0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48))
    static let iidPixelSnapping = guid(
      0xeaf3_a2da, 0xecf4, 0x4d24, (0xb6, 0x44, 0xb3, 0x4f, 0x68, 0x42, 0x02, 0x4b))
    static let iidTextRenderer = guid(
      0xef8a_8135, 0x5cc6, 0x45fe, (0x88, 0x25, 0xc5, 0xa0, 0x72, 0x4e, 0xb8, 0x19))

    static func guid(
      _ a: UInt32, _ b: UInt16, _ c: UInt16, _ d: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    ) -> GUID {
      GUID(Data1: a, Data2: b, Data3: c, Data4: d)
    }

    static func equal(_ a: UnsafePointer<IID>?, _ b: GUID) -> Bool {
      guard let a else { return false }
      var b = b
      return memcmp(a, &b, MemoryLayout<GUID>.size) == 0
    }

    /// `string` as the null-terminated UTF-16 Windows takes, for the length of `body`.
    static func wide<Result>(_ string: String, _ body: (UnsafePointer<WCHAR>) -> Result) -> Result {
      let characters = Array(string.utf16) + [0]
      return characters.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
  }
#endif
