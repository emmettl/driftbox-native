#if os(Linux)
  import DriftboxText
  import DriftboxTextLinux
  import Testing

  struct PangoTypesetterTests {
    let font = FontRequest(families: ["DejaVu Sans"], size: 24)

    @Test func shapingPreservesSpacesAndCombiningMarks() {
      let type = PangoTypesetter()
      let base = type.line("café", font: font)
      let decomposed = type.line("cafe\u{301}", font: font)
      #expect(base.width > 0)
      #expect(abs(base.width - decomposed.width) < 0.1)
      #expect(type.line("café  ", font: font).width > base.width)
      #expect(base.ascent > 0 && base.descent >= 0)
      #expect(type.line("", font: font).width == 0)
    }

    @Test func glyphCoverageKeepsBaselineAndFractionalPosition() throws {
      let type = PangoTypesetter()
      let line = type.line("Ag", font: font)
      let letter = try #require(line.glyphs.first)
      let whole = try #require(type.coverage(letter.glyph, offset: 0))
      let fraction = try #require(type.coverage(letter.glyph, offset: 0.25))
      #expect(whole.top < 0)
      #expect(whole.bytes.count == whole.width * whole.height)
      #expect(whole.bytes.contains { $0 > 0 })
      #expect(whole.bytes != fraction.bytes)
      let repeated = type.line("Ag", font: font)
      #expect(repeated.glyphs == line.glyphs)
    }

    @Test func fallbackAndRightToLeftTextProduceCoverage() {
      let type = PangoTypesetter()
      for text in ["العربية", "\u{10FFFF}"] {
        let line = type.line(text, font: FontRequest(families: ["No Such Driftbox Font"], size: 24))
        #expect(line.width > 0 && !line.family.isEmpty)
        #expect(!line.glyphs.isEmpty)
        #expect(line.glyphs.allSatisfy { $0.origin.x.isFinite && $0.origin.y.isFinite })
        #expect(
          line.glyphs.contains { type.coverage($0.glyph, offset: 0)?.bytes.contains { $0 > 0 } == true })
      }
    }
  }
#endif
