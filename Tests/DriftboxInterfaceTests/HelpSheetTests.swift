import DriftboxCanvas
import DriftboxHelp
import DriftboxInterface
import DriftboxRack
import DriftboxRackSession
import DriftboxShell
import Foundation
import Testing

#if os(macOS)
  import DriftboxGPUMetal
  import DriftboxTextMac
#endif

/// A module's guide on the drawn rack, as Windows and Android show it: from the module's menu, a
/// page over the rack that scrolls when it is longer than the window, and closes on its cross, a
/// press off it, or Escape.
@MainActor
struct HelpSheetTests {
  static let size = SIMD2<Float>(800, 600)

  static func rack() throws -> RackInterface {
    let (face, _) = try RackInterfaceTests.alone("alligator")
    face.size = size
    return face
  }

  static func tap(_ face: RackInterface, _ at: SIMD2<Float>) {
    face.pointer(PointerEvent(phase: .began, location: at))
    face.pointer(PointerEvent(phase: .ended, location: at))
  }

  /// Drawn once, so it has laid its words out and knows how long it is.
  static func draw(_ face: RackInterface) throws {
    #if os(macOS)
      let canvas = try Canvas(device: try MetalDevice(), typesetter: CoreTextTypesetter())
      try canvas.begin(width: Int(size.x), height: Int(size.y))
      face.draw(on: canvas)
      _ = canvas.finish()
    #endif
  }

  @Test func theModulesMenuOpensItsGuide() throws {
    let face = try Self.rack()
    let at = try #require(face.stage.faces.first).frame
    let menu = try #require(face.menu(at: RackInterfaceTests.window(face.stage, SIMD2(at.x + 20, at.y + 20))))
    #expect(menu.commands.first?.title == "Guide")
    face.choose("module.guide")
    let guide = try #require(face.guide)
    #expect(guide.title == "Alligator" && guide.parts.map(\.heading).first == "What it does")

    // A press on the page keeps it, and one off it closes it.
    let frame = HelpSheet.frame(in: Self.size)
    Self.tap(face, SIMD2(frame.x + 40, frame.y + 200))
    #expect(face.guide != nil)
    Self.tap(face, SIMD2(frame.x - 5, 300))
    #expect(face.guide == nil)

    // Its cross, and Escape, close it too; and it has every key while it is open.
    face.showGuide("alligator")
    let close = HelpSheet.close(in: frame)
    Self.tap(face, SIMD2(close.x + 16, close.y + 16))
    #expect(face.guide == nil)
    face.showGuide("alligator")
    #expect(face.key(KeyEvent(key: .character("a"))))
    #expect(face.guide != nil)
    #expect(face.key(KeyEvent(key: .escape)))
    #expect(face.guide == nil)
  }

  /// Longer than the window, it scrolls, by a wheel or a finger, and no further than its end; and
  /// a drag is a scroll rather than a press that closes it.
  @Test func aLongGuideScrolls() throws {
    #if os(macOS)
      let face = try Self.rack()
      face.showGuide("alligator")
      let guide = try #require(face.guide)
      try Self.draw(face)
      let room = HelpSheet.body(in: HelpSheet.frame(in: Self.size)).height
      #expect(
        guide.contentHeight > room, "Alligator's guide is longer than 600 points: \(guide.contentHeight)")
      face.scroll(ScrollEvent(location: SIMD2(400, 300), delta: SIMD2(0, 120)))
      #expect(guide.scroll == 120)
      face.scroll(ScrollEvent(location: SIMD2(400, 300), delta: SIMD2(0, 100_000)))
      #expect(guide.scroll == guide.contentHeight - room, "no further than its end")

      face.pointer(PointerEvent(phase: .began, location: SIMD2(700, 300)))
      face.pointer(PointerEvent(phase: .moved, location: SIMD2(700, 400)))
      face.pointer(PointerEvent(phase: .ended, location: SIMD2(700, 400)))
      #expect(face.guide != nil, "a drag, off the page or on it, scrolls and does not close it")
      #expect(guide.scroll == guide.contentHeight - room - 100)
    #endif
  }
}
