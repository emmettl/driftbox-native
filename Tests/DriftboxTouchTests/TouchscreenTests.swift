import DriftboxGPU
import DriftboxHost
import DriftboxSession
import DriftboxShell
import DriftboxText
import DriftboxTouch
import Testing

#if os(Windows)
  import DriftboxGPUD3D11
#elseif canImport(Metal)
  import DriftboxGPUMetal
  import Metal
#elseif os(Linux)
  import DriftboxGPUGLES
#endif

/// What a finger on a touch screen is: the controls', the pad's, or a gesture's. Held on whichever
/// GPU this platform has, since the touch screen draws the scene it steps through; nothing here is
/// drawn.
@MainActor
struct TouchscreenTests {
  static func device() throws -> (any GPUDevice)? {
    #if os(Windows)
      return try D3D11Device(driver: .software)
    #elseif canImport(Metal)
      return MTLCreateSystemDefaultDevice() == nil ? nil : try MetalDevice()
    #elseif os(Linux)
      return try GLESDevice()
    #else
      return nil
    #endif
  }

  /// A phone's screen in points, playing acid.
  static func screen() throws -> Touchscreen? {
    guard let device = try device() else { return nil }
    let session = Session(host: EngineHost(sampleRate: 48000))
    guard let acid = session.entries.first(where: { $0.id == "acid" }) else { return nil }
    session.open(acid)
    let screen = try Touchscreen(session: session, device: device, typesetter: NoType(), scale: 3)
    screen.interface.size = SIMD2(372, 828)
    return screen
  }

  /// A point on the screen that no panel of the controls covers.
  static func open(_ screen: Touchscreen) -> SIMD2<Float>? {
    let panels = screen.interface.layout.panels
    for y in stride(from: Float(10), to: 820, by: 10) {
      let point = SIMD2(Float(186), y)
      if !panels.contains(where: { $0.contains(point) }) { return point }
    }
    return nil
  }

  static func finger(_ phase: PointerEvent.Phase, _ id: Int, _ at: SIMD2<Float>) -> PointerEvent {
    PointerEvent(phase: phase, id: id, kind: .touch, location: at)
  }

  @Test func aFingerOnTheControlsIsNotThePads() throws {
    guard let screen = try Self.screen(), let bar = screen.interface.layout.panels.first else { return }
    let on = SIMD2(bar.x + bar.width / 2, bar.y + bar.height / 2)
    screen.touch(Self.finger(.began, 1, on))
    screen.touch(Self.finger(.moved, 1, on + SIMD2(0, 200)))
    #expect(screen.session.padTouch == nil, "the controls', wherever it goes")
    screen.touch(Self.finger(.ended, 1, on + SIMD2(0, 200)))
  }

  @Test func theFirstFingerElsewhereIsThePads() throws {
    guard let screen = try Self.screen(), let point = Self.open(screen) else { return }
    screen.touch(Self.finger(.began, 1, point))
    let touched = try #require(screen.session.padTouch)
    #expect(abs(touched.x - 0.5) < 0.01, "0...1 across")
    #expect(abs(touched.y - (1 - point.y / 828)) < 0.01, "and 0...1 up from the bottom")
    screen.touch(Self.finger(.ended, 1, point))
    #expect(screen.session.padTouch == nil, "and lifting it lets the pad go")
  }

  @Test func aSecondFingerStepsOnToTheNextScene() throws {
    guard let screen = try Self.screen(), let point = Self.open(screen) else { return }
    let showing = screen.sceneID
    screen.touch(Self.finger(.began, 1, point))
    screen.touch(Self.finger(.began, 2, point + SIMD2(40, 0)))
    #expect(screen.chosenScene != nil && screen.chosenScene != showing, "the next scene")
    let touched = screen.session.padTouch
    screen.touch(Self.finger(.moved, 2, point + SIMD2(80, 0)))
    #expect(screen.session.padTouch == touched, "and the pad stays the first finger's")
    screen.touch(Self.finger(.ended, 2, point + SIMD2(80, 0)))
    screen.touch(Self.finger(.ended, 1, point))
  }
}

/// Sets nothing: nothing here is drawn.
final class NoType: Typesetter {
  func line(_ text: String, font: FontRequest) -> TextLine {
    TextLine(glyphs: [], width: 0, ascent: 0, descent: 0, family: "none")
  }
  func coverage(_ glyph: Glyph, offset: Float) -> GlyphCoverage? { nil }
}
