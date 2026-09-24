import DriftboxCanvas
import DriftboxGPU
import DriftboxText
import Testing

#if os(Windows)
  import DriftboxGPUD3D11
  import DriftboxTextWindows
#elseif canImport(Metal)
  import DriftboxGPUMetal
  import Metal
#elseif os(Linux)
  import DriftboxGPUGLES
#endif

/// The canvas on every backend this platform has, held to what Canvas2D draws: where a shape
/// covers and how much, what the transform and the clip do, the blends, the state `save` keeps,
/// and the page drawn onto itself. Type is held here to landing where it is put; what it looks
/// like is the typesetter's, and `TypesetterTests` holds that.
enum Devices {
  static func all() throws -> [any GPUDevice] {
    #if os(Windows)
      return [try D3D11Device(driver: .software)]
    #elseif canImport(Metal)
      return MTLCreateSystemDefaultDevice() == nil ? [] : [try MetalDevice()]
    #elseif os(Linux)
      return [try GLESDevice()]
    #else
      return []
    #endif
  }

  /// The platform's typesetter, where it has one, for the tests of type.
  static func typesetter() throws -> (any Typesetter)? {
    #if os(Windows)
      return try DirectWriteTypesetter()
    #else
      return nil
    #endif
  }
}

/// For the tests that draw no type: sets nothing.
final class NoType: Typesetter {
  func line(_ text: String, font: FontRequest) -> TextLine {
    TextLine(glyphs: [], width: 0, ascent: 0, descent: 0, family: "none")
  }
  func coverage(_ glyph: Glyph, offset: Float) -> GlyphCoverage? { nil }
}

/// Sets nothing either, but counts the lines it is asked to set.
final class CountingType: Typesetter {
  var set: [String] = []
  func line(_ text: String, font: FontRequest) -> TextLine {
    set.append("\(text) at \(font.size)")
    return TextLine(glyphs: [], width: Float(text.count), ascent: 0, descent: 0, family: "none")
  }
  func coverage(_ glyph: Glyph, offset: Float) -> GlyphCoverage? { nil }
}

/// A page's pixel at `(x, y)` from the top left, as red, green, blue, alpha, 0...255.
func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int, width: Int) -> SIMD4<Int> {
  let at = (y * width + x) * 4
  return SIMD4(Int(bytes[at + 2]), Int(bytes[at + 1]), Int(bytes[at]), Int(bytes[at + 3]))
}

func near(_ a: SIMD4<Int>, _ b: SIMD4<Int>, within: Int = 2) -> Bool {
  let d = a &- b
  return abs(d.x) <= within && abs(d.y) <= within && abs(d.z) <= within && abs(d.w) <= within
}

let red = SIMD4(255, 0, 0, 255)
let clear = SIMD4(0, 0, 0, 0)

struct CanvasTests {
  /// Draw on a fresh `size` page with `body`, and read it back.
  static func page(
    _ device: any GPUDevice, _ size: Int = 16, typesetter: any Typesetter = NoType(),
    _ body: (Canvas) -> Void
  ) throws -> [UInt8] {
    let canvas = try Canvas(device: device, typesetter: typesetter)
    try canvas.begin(width: size, height: size)
    body(canvas)
    return try device.readPixels(canvas.finish())
  }

  /// A line is set once and drawn again from what was set, for as long as each page uses it; a
  /// line a whole page goes without is let go of, and set again if it comes back.
  @Test func aLineIsSetOnceWhilePagesUseIt() throws {
    for device in try Devices.all() {
      let typesetter = CountingType()
      let canvas = try Canvas(device: device, typesetter: typesetter)
      let small = FontRequest(families: ["Arial"], size: 12)
      var large = small
      large.size = 24

      try canvas.begin(width: 16, height: 16)
      canvas.font = small
      canvas.fillText("BPM", 0, 10)
      canvas.fillText("BPM", 0, 12)
      #expect(canvas.measure("BPM") == 3, "measured from the line set")
      canvas.font = large
      canvas.fillText("BPM", 0, 14)
      #expect(typesetter.set == ["BPM at 12.0", "BPM at 24.0"], "once in each font")

      try canvas.begin(width: 16, height: 16)
      canvas.font = small
      canvas.fillText("BPM", 0, 10)
      canvas.fillText("00:01", 0, 12)
      #expect(typesetter.set.count == 3, "the page before's line kept, and only the new one set")

      try canvas.begin(width: 16, height: 16)
      canvas.font = small
      canvas.fillText("00:02", 0, 12)
      try canvas.begin(width: 16, height: 16)
      canvas.font = small
      canvas.fillText("BPM", 0, 10)
      #expect(
        typesetter.set.suffix(2) == ["00:02 at 12.0", "BPM at 12.0"],
        "a line a page went without is set again: \(typesetter.set)")
      _ = canvas.finish()
    }
  }

  /// A rectangle covers the pixels inside it, and half covers a pixel its edge halves.
  @Test func aRectangleCoversWhatItCovers() throws {
    for device in try Devices.all() {
      let read = try Self.page(device) { canvas in
        canvas.fill = Colour(0xff0000)
        canvas.fillRect(4, 4, 8, 8)
        canvas.fillRect(0, 14, 1.5, 1)
      }
      #expect(near(pixel(read, 4, 4, width: 16), red), "its first pixel")
      #expect(near(pixel(read, 11, 11, width: 16), red), "and its last")
      #expect(near(pixel(read, 3, 7, width: 16), clear), "nothing outside")
      #expect(near(pixel(read, 12, 7, width: 16), clear))
      #expect(
        near(pixel(read, 1, 14, width: 16), SIMD4(128, 0, 0, 128), within: 3), "half a pixel, half covered")
    }
  }

  /// The transform places a shape: moved, then turned a quarter clockwise about the new origin.
  @Test func theTransformPlacesAShape() throws {
    for device in try Devices.all() {
      let read = try Self.page(device) { canvas in
        canvas.fill = Colour(0xff0000)
        canvas.translate(8, 2)
        canvas.rotate(.pi / 2)
        // Along x, which is now down the page; 2 high, which is now 2 to the left.
        canvas.fillRect(0, 0, 10, 2)
      }
      #expect(near(pixel(read, 7, 6, width: 16), red), "down the page")
      #expect(near(pixel(read, 6, 6, width: 16), red))
      #expect(near(pixel(read, 8, 6, width: 16), clear), "and not to the right of where it turned")
      #expect(near(pixel(read, 7, 13, width: 16), clear), "nor past its length")
    }
  }

  /// Nothing lands outside the clip, and `restore` takes the clip, the fill and the transform
  /// back to what `save` kept.
  @Test func theClipAndRestore() throws {
    for device in try Devices.all() {
      let read = try Self.page(device) { canvas in
        canvas.fill = Colour(0xff0000)
        canvas.save()
        canvas.clip(4, 4, 8, 8)
        canvas.translate(100, 100)
        canvas.fill = Colour(0x00ff00)
        canvas.fillRect(-100, -100, 16, 16)
        canvas.restore()
        canvas.fillRect(0, 0, 2, 2)
      }
      #expect(near(pixel(read, 6, 6, width: 16), SIMD4(0, 255, 0, 255)), "inside the clip")
      #expect(near(pixel(read, 13, 6, width: 16), clear), "and nothing outside it")
      #expect(near(pixel(read, 1, 1, width: 16), red), "then red again, unclipped, unmoved")
    }
  }

  /// Multiply darkens what is there by what is drawn: cyan on yellow is green, and a half-covered
  /// multiply darkens half as much.
  @Test func multiplyDarkens() throws {
    for device in try Devices.all() {
      let read = try Self.page(device) { canvas in
        canvas.fill = Colour(0xffff00)
        canvas.fillRect(0, 0, 16, 16)
        canvas.blend = .multiply
        canvas.fill = Colour(0x00ffff)
        canvas.fillRect(0, 0, 8, 16)
        canvas.fill = Colour(0x00ffff, alpha: 0.5)
        canvas.fillRect(8, 0, 8, 16)
      }
      #expect(near(pixel(read, 3, 3, width: 16), SIMD4(0, 255, 0, 255)))
      #expect(near(pixel(read, 12, 3, width: 16), SIMD4(128, 255, 0, 255), within: 3))
    }
  }

  /// An ellipse covers its middle and not its bounding box's corners, and is antialiased at its edge.
  @Test func anEllipseIsRound() throws {
    for device in try Devices.all() {
      let read = try Self.page(device, 32) { canvas in
        canvas.fill = Colour(0xff0000)
        canvas.fillEllipse(0, 0, 32, 32)
      }
      #expect(near(pixel(read, 16, 16, width: 32), red))
      #expect(near(pixel(read, 1, 1, width: 32), clear))
      // Round the rim, where the edge crosses pixels at every slant, some are partly covered.
      let partial = (0..<32).flatMap { y in (0..<32).map { pixel(read, $0, y, width: 32).w } }
        .filter { $0 > 20 && $0 < 235 }.count
      #expect(partial > 40, "partly covered round the rim: \(partial) pixels")
    }
  }

  /// A rounded rectangle covers its edges but not its corners, and its corners scale with the
  /// transform: the same shape drawn at half the size under a scale of two is the same pixels.
  @Test func roundedCornersAreRound() throws {
    for device in try Devices.all() {
      let read = try Self.page(device, 32) { canvas in
        canvas.fill = Colour(0xff0000)
        canvas.fillRoundedRect(0, 0, 32, 32, radius: 8)
      }
      #expect(near(pixel(read, 16, 16, width: 32), red))
      #expect(near(pixel(read, 16, 0, width: 32), red), "its top edge, straight")
      #expect(near(pixel(read, 0, 16, width: 32), red), "its left edge")
      #expect(near(pixel(read, 1, 1, width: 32), clear), "but not the corner")
      #expect(near(pixel(read, 30, 30, width: 32), clear), "any corner")
      let scaled = try Self.page(device, 32) { canvas in
        canvas.fill = Colour(0xff0000)
        canvas.scale(2, 2)
        canvas.fillRoundedRect(0, 0, 16, 16, radius: 4)
      }
      #expect(zip(read, scaled).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "the same under a scale")
    }
  }

  /// A rounded fill runs from its colour at the top to its foot's at the bottom.
  @Test func aFillRunsToItsFoot() throws {
    for device in try Devices.all() {
      let read = try Self.page(device) { canvas in
        canvas.fill = Colour(0xff0000)
        canvas.fillRoundedRect(0, 0, 16, 16, radius: 0, foot: Colour(0x0000ff))
      }
      let top = pixel(read, 8, 0, width: 16)
      let middle = pixel(read, 8, 8, width: 16)
      let bottom = pixel(read, 8, 15, width: 16)
      #expect(top.x > 240 && top.z < 15, "red at the top: \(top)")
      #expect(bottom.z > 240 && bottom.x < 15, "blue at the foot: \(bottom)")
      #expect(abs(middle.x - middle.z) < 20 && middle.w == 255, "and half and half between: \(middle)")
    }
  }

  /// A border is its line width inside the rectangle's edge, and nothing within.
  @Test func aBorderIsInsideItsEdge() throws {
    for device in try Devices.all() {
      let read = try Self.page(device) { canvas in
        canvas.stroke = Colour(0xff0000)
        canvas.lineWidth = 2
        canvas.strokeRoundedRect(2, 2, 12, 12, radius: 0)
      }
      #expect(near(pixel(read, 2, 8, width: 16), red))
      #expect(near(pixel(read, 3, 8, width: 16), red))
      #expect(near(pixel(read, 13, 8, width: 16), red), "on every side")
      #expect(near(pixel(read, 8, 2, width: 16), red))
      #expect(near(pixel(read, 1, 8, width: 16), clear), "nothing outside")
      #expect(near(pixel(read, 4, 8, width: 16), clear), "nor inside the line")
      #expect(near(pixel(read, 8, 8, width: 16), clear))
    }
  }

  /// Type under an even scale is set at the size it lands on the page, not set small and
  /// magnified: the same pixels as the larger type drawn where the scale puts it.
  @Test func scaledTypeIsSharp() throws {
    guard let typesetter = try Devices.typesetter() else { return }
    for device in try Devices.all() {
      let read = try Self.page(device, 64, typesetter: typesetter) { canvas in
        canvas.font = FontRequest(families: ["Arial"], size: 32)
        canvas.fill = Colour(0xff0000)
        canvas.fillText("Ag", 10, 44)
      }
      let scaled = try Self.page(device, 64, typesetter: typesetter) { canvas in
        canvas.font = FontRequest(families: ["Arial"], size: 16)
        canvas.fill = Colour(0xff0000)
        canvas.scale(2, 2)
        canvas.fillText("Ag", 5, 22)
      }
      #expect(read.contains { $0 > 128 }, "something drawn")
      #expect(read == scaled)
    }
  }

  /// A stroked line is its width across, centred on the line.
  @Test func aLineIsItsWidthAcross() throws {
    for device in try Devices.all() {
      let read = try Self.page(device) { canvas in
        canvas.stroke = Colour(0xff0000)
        canvas.lineWidth = 2
        canvas.strokeLines([(SIMD2(2, 8), SIMD2(14, 8))])
      }
      #expect(near(pixel(read, 8, 7, width: 16), red))
      #expect(near(pixel(read, 8, 8, width: 16), red))
      #expect(near(pixel(read, 8, 6, width: 16), clear))
      #expect(near(pixel(read, 8, 9, width: 16), clear))
      #expect(near(pixel(read, 1, 8, width: 16), clear), "and ends where it ends")
    }
  }

  /// The page drawn onto itself, moved: what was on the left, copied to the right inside a clip —
  /// and a second copy reads what the first left, so a run of them compounds.
  @Test func thePageOntoItself() throws {
    for device in try Devices.all() {
      let read = try Self.page(device) { canvas in
        canvas.fill = Colour(0xff0000)
        canvas.fillRect(0, 0, 4, 16)
        canvas.save()
        canvas.clip(4, 0, 12, 8)
        canvas.drawPage(shiftedBy: SIMD2(4, 0))
        canvas.drawPage(shiftedBy: SIMD2(4, 0))
        canvas.restore()
      }
      #expect(near(pixel(read, 1, 12, width: 16), red), "the original stays")
      #expect(near(pixel(read, 5, 4, width: 16), red), "copied once")
      #expect(near(pixel(read, 9, 4, width: 16), red), "and the copy copied")
      #expect(near(pixel(read, 13, 4, width: 16), clear), "but no further")
      #expect(near(pixel(read, 5, 12, width: 16), clear), "and nothing outside the clip")
    }
  }

  /// Type lands where it is put: on its baseline, starting at x, or ending there when aligned
  /// right; and turned with the transform.
  @Test func typeLandsWhereItIsPut() throws {
    guard let typesetter = try Devices.typesetter() else { return }
    for device in try Devices.all() {
      let font = FontRequest(families: ["Arial Black", "Arial"], weight: 900, size: 40)
      let width = typesetter.line("II", font: font).width
      let read = try Self.page(device, 128, typesetter: typesetter) { canvas in
        canvas.font = font
        canvas.fill = Colour(0xff0000)
        canvas.fillText("II", 10, 50)
        canvas.align = .right
        canvas.fillText("II", 118, 110)
      }
      func inked(_ x: ClosedRange<Int>, _ y: ClosedRange<Int>) -> Bool {
        y.contains { row in x.contains { pixel(read, $0, row, width: 128).w > 128 } }
      }
      #expect(inked(10...(10 + Int(width)), 25...49), "left: after x, above the baseline")
      #expect(!inked(0...8, 0...127), "and nothing before x")
      #expect(!inked(0...127, 52...60), "nor below the baseline")
      #expect(inked((118 - Int(width))...118, 85...109), "right: ending at x")
      #expect(!inked(120...127, 0...127), "and nothing after it")
    }
  }
}
