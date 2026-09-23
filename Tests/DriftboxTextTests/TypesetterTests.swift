import DriftboxText
import Testing

#if os(Windows)
  import DriftboxTextWindows
#endif

/// What every platform's typesetter must do the same way, run against whichever this platform has.
/// Fonts differ between platforms, so these hold a typesetter to how type behaves — kerned, scaled,
/// falling back, standing on its baseline — rather than to any one font's numbers.
enum Typesetters {
  static func all() throws -> [any Typesetter] {
    #if os(Windows)
      return [try DirectWriteTypesetter()]
    #else
      return []
    #endif
  }
}

struct TypesetterTests {
  static let arial = FontRequest(families: ["Arial"], weight: 400, size: 100)

  /// The first family installed is the one used; when none is, the platform's own.
  @Test func aFontFallsBackThroughItsFamilies() throws {
    for typesetter in try Typesetters.all() {
      let asked = typesetter.line(
        "Driftbox", font: FontRequest(families: ["No Such Face", "Arial"], size: 32))
      #expect(asked.family == "Arial")
      let none = typesetter.line("Driftbox", font: FontRequest(families: ["No Such Face"], size: 32))
      #expect(none.family != "No Such Face")
      #expect(none.width > 0, "and still sets the line, in the fallback")
    }
  }

  /// One glyph a letter, left to right along the baseline, and the width the pen travelled.
  @Test func aLineIsGlyphsAlongTheBaseline() throws {
    for typesetter in try Typesetters.all() {
      let line = typesetter.line("Driftbox", font: Self.arial)
      #expect(line.glyphs.count == 8)
      #expect(line.glyphs.allSatisfy { $0.origin.y == 0 })
      #expect(zip(line.glyphs, line.glyphs.dropFirst()).allSatisfy { $0.origin.x < $1.origin.x })
      #expect(line.glyphs.first?.origin.x == 0)
      #expect(line.width > line.glyphs.last!.origin.x)
      #expect(line.ascent > 50 && line.ascent < 120, "Arial's ascent is most of an em: \(line.ascent)")
      #expect(line.descent > 10 && line.descent < 40, "and its descent a fifth: \(line.descent)")
    }
  }

  /// Type scales: twice the size is twice as wide, since nothing is snapped to pixels.
  @Test func widthScalesWithSize() throws {
    for typesetter in try Typesetters.all() {
      var twice = Self.arial
      twice.size = 200
      let small = typesetter.line("Graphic Lab", font: Self.arial).width
      let large = typesetter.line("Graphic Lab", font: twice).width
      #expect(abs(large - small * 2) < 0.01, "\(small) and \(large)")
    }
  }

  /// Kerned as the font says, as a canvas kerns: A and V sit closer together than each alone.
  @Test func pairsAreKerned() throws {
    for typesetter in try Typesetters.all() {
      let pair = typesetter.line("AV", font: Self.arial).width
      let apart = typesetter.line("A", font: Self.arial).width + typesetter.line("V", font: Self.arial).width
      #expect(pair < apart - 1, "AV \(pair), A and V \(apart)")
    }
  }

  /// The width is how far the pen went, trailing spaces and all, as `measureText` measures.
  @Test func trailingSpacesAreMeasured() throws {
    for typesetter in try Typesetters.all() {
      let bare = typesetter.line("A", font: Self.arial).width
      let spaced = typesetter.line("A ", font: Self.arial).width
      #expect(spaced > bare + 10)
    }
  }

  /// An I stands on the baseline, as tall as a capital, solid through its middle; a space covers
  /// nothing; and a glyph a fraction of a pixel along is drawn differently.
  @Test func coverageIsTheGlyphOnItsBaseline() throws {
    for typesetter in try Typesetters.all() {
      let black = FontRequest(families: ["Arial Black", "Arial"], weight: 900, size: 100)
      let line = typesetter.line("I ", font: black)
      let letter = try #require(line.glyphs.first).glyph
      let coverage = try #require(typesetter.coverage(letter, offset: 0))
      #expect(
        coverage.top < -60 && coverage.top > -80, "a capital's height above the baseline: \(coverage.top)")
      #expect(coverage.top + coverage.height >= -1 && coverage.top + coverage.height <= 2, "and down to it")
      #expect(coverage.left >= 0 && coverage.left < 20)
      #expect(coverage[coverage.width / 2, coverage.height / 2] == 255, "solid through the middle")
      #expect(coverage[0, coverage.height / 2] < 255, "and antialiased at its edge")

      let space = try #require(line.glyphs.last).glyph
      #expect(typesetter.coverage(space, offset: 0) == nil)

      let along = try #require(typesetter.coverage(letter, offset: 0.5))
      #expect(along.bytes != coverage.bytes, "half a pixel along is not the same bitmap")
    }
  }
}
