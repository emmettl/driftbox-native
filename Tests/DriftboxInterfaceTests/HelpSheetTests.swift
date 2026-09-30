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
#elseif os(Windows)
  import DriftboxGPUD3D11
  import DriftboxTextWindows
#endif

/// Help drawn over a screen, as Windows and Android show it: a whole guide with a tab for each
/// topic, from the Help menu, and a module's guide, from its menu on the rack. It scrolls when it
/// is longer than the window, closes on Close, a press off it, or Escape, and is read by a screen
/// reader as the controls are.
@MainActor
struct HelpSheetTests {
  static let size = SIMD2<Float>(800, 600)

  static func sheet() -> HelpSheet {
    let sheet = HelpSheet(guide: GrooveboxHelp.guide(for: .mac))
    sheet.size = SIMD2(900, 600)
    return sheet
  }

  static func rack() throws -> RackInterface {
    let (face, _) = try RackInterfaceTests.alone("alligator")
    face.size = size
    return face
  }

  /// The added lessons remain reachable on a phone, with room to read beneath the wrapped tabs.
  @Test func lessonsFitOnAPhoneAndScrollToTheEnd() {
    for guide in [GrooveboxHelp.guide(for: .android), RackHelp.guide(for: .android)] {
      let sheet = HelpSheet(guide: guide)
      sheet.size = SIMD2(390, 600)
      for topic in guide.topics {
        #expect(sheet.perform(.press("help.topic." + topic.id)))
        #expect(sheet.room.height > 200)
        #expect(sheet.room.width > 300)
        sheet.scroll(ScrollEvent(location: .zero, delta: SIMD2(0, 100_000)))
        #expect(sheet.scroll == max(0, sheet.contentHeight - sheet.room.height))
      }
    }
  }

  static func centre(_ node: AccessibilityNode) -> SIMD2<Float> {
    SIMD2(node.frame.x + node.frame.z / 2, node.frame.y + node.frame.w / 2)
  }

  static func tap(_ pointer: (PointerEvent) -> Void, _ at: SIMD2<Float>) {
    pointer(PointerEvent(phase: .began, location: at))
    pointer(PointerEvent(phase: .ended, location: at))
  }

  /// Drawn once, so it has laid its words out with the canvas's measures.
  static func draw(_ face: RackInterface) throws {
    #if os(macOS)
      let canvas = try Canvas(device: try MetalDevice(), typesetter: CoreTextTypesetter())
      try canvas.begin(width: Int(size.x), height: Int(size.y))
      face.draw(on: canvas)
      _ = canvas.finish()
    #endif
  }

  // MARK: - A guide

  /// Close, a tab for each topic, the first lit; and every heading, paragraph, term, step and key of
  /// the topic showing, in order, each where it is on the page.
  @Test func aScreenReaderReadsIt() throws {
    let sheet = Self.sheet()
    let page = try #require(sheet.accessibility.node("help"))
    #expect(page.name == "Groovebox guide")
    #expect(page.node("help.close")?.role == .button)
    let tabs = page.children.filter { $0.id.hasPrefix("help.topic.") }
    #expect(tabs.map(\.name) == sheet.guide.topics.map(\.label))
    #expect(tabs.map(\.isOn) == sheet.guide.topics.indices.map { $0 == 0 })

    let words = page.children.filter { $0.role == .text }
    let first = try #require(sheet.guide.topics.first)
    #expect(words.first?.name == first.parts.first?.heading)
    #expect(words.contains { $0.name.hasPrefix("Step 1: ") })
    #expect(words.allSatisfy { $0.frame.z > 0 && $0.frame.w > 0 })
    let ys = words.map(\.frame.y)
    #expect(ys == ys.sorted(), "down the page in order")
  }

  /// A tab pressed, by a click or a screen reader, shows its topic from the top; Close closes.
  @Test func topicsAreChosenAndItCloses() throws {
    let sheet = Self.sheet()
    let song = try #require(sheet.accessibility.node("help.topic.song"))
    Self.tap(sheet.pointer, Self.centre(song))
    #expect(sheet.guide.topics[sheet.topic].id == "song" && sheet.isOpen)
    #expect(sheet.accessibility.node("help.topic.song")?.isOn == true)

    #expect(sheet.perform(.press("help.topic.keys")))
    #expect(sheet.guide.topics[sheet.topic].id == "keys")
    #expect(!sheet.perform(.press("help.topic.nowhere")))
    #expect(sheet.perform(.press("help.close")))
    #expect(!sheet.isOpen)
  }

  /// The wheel and the keys scroll it, never past its ends; Left and Right go to the topics beside;
  /// Esc closes it; and every key is its own.
  @Test func theKeysMoveAboutIt() {
    let sheet = HelpSheet(guide: GrooveboxHelp.guide(for: .mac))
    sheet.size = SIMD2(500, 300)
    #expect(sheet.key(KeyEvent(key: .pageDown)))
    #expect(sheet.scroll > 0)
    sheet.scroll(ScrollEvent(location: .zero, delta: SIMD2(0, -10_000)))
    #expect(sheet.scroll == 0)
    #expect(sheet.key(KeyEvent(key: .end)))
    let bottom = sheet.scroll
    #expect(sheet.key(KeyEvent(key: .down)))
    #expect(sheet.scroll == bottom, "no further than its end")

    #expect(sheet.key(KeyEvent(key: .right)))
    #expect(sheet.topic == 1 && sheet.scroll == 0)
    #expect(sheet.key(KeyEvent(key: .left)))
    #expect(sheet.key(KeyEvent(key: .left)))
    #expect(sheet.topic == 0)
    #expect(sheet.key(KeyEvent(key: .character("a"))), "nothing plays under it")
    #expect(sheet.key(KeyEvent(key: .escape)))
    #expect(!sheet.isOpen)
  }

  /// Drawn: the words are set from where each starts, as it was laid out — a heading's ink runs
  /// from the column's left as far as the heading is wide, not centred on its start.
  @Test func theWordsAreSetWhereTheyWereLaidOut() throws {
    #if os(Windows)
      let device = try D3D11Device(driver: .software)
      let canvas = try Canvas(device: device, typesetter: try DirectWriteTypesetter())
      let sheet = HelpSheet(trail: "Test", title: "A page", parts: [HelpPart("Headings", .prose(["Words."]))])
      sheet.size = SIMD2(800, 600)
      try canvas.begin(width: 800, height: 600)
      sheet.draw(on: canvas)
      let read = try device.readPixels(canvas.finish())
      canvas.font = Theme.sans(15, weight: 600)
      let wide = canvas.measure("Headings")
      let body = sheet.room
      // The rightmost bright pixel along the heading's line.
      var last = 0
      for y in Int(body.y)..<Int(body.y + 18) {
        for x in Int(body.x - 4)..<Int(body.maxX) where read[(y * 800 + x) * 4 + 1] > 160 {
          last = max(last, x)
        }
      }
      #expect(
        abs(Float(last) - (body.x + wide)) < 4, "ink to \(last), the heading \(body.x)…\(body.x + wide)")
    #endif
  }

  // MARK: - A module's guide

  @Test func theModulesMenuOpensItsGuide() throws {
    let face = try Self.rack()
    let at = try #require(face.stage.faces.first).frame
    let menu = try #require(face.menu(at: RackInterfaceTests.window(face.stage, SIMD2(at.x + 20, at.y + 20))))
    #expect(menu.commands.first?.title == "Guide")
    face.choose("module.guide")
    let guide = try #require(face.guide)
    #expect(guide.title == "Alligator" && guide.parts.map(\.heading).first == "What it does")
    #expect(guide.accessibility.node("help.topic.page") == nil, "one page, no tabs")

    // A press on the page keeps it, and one off it closes it.
    let frame = HelpSheet.frame(in: Self.size)
    Self.tap(face.pointer, SIMD2(frame.x + 40, frame.y + 200))
    #expect(face.guide != nil)
    Self.tap(face.pointer, SIMD2(frame.x - 5, 300))
    #expect(face.guide == nil)

    // Its Close, and Escape, close it too; and it has every key while it is open.
    face.showGuide("alligator")
    let close = try #require(face.guide?.accessibility.node("help.close"))
    Self.tap(face.pointer, Self.centre(close))
    #expect(face.guide == nil)
    face.showGuide("alligator")
    #expect(face.key(KeyEvent(key: .character("a"))))
    #expect(face.guide != nil)
    #expect(face.key(KeyEvent(key: .escape)))
    #expect(face.guide == nil)
  }

  /// While a module's guide is open, a screen reader reads it in the rack's place, and closes it.
  @Test func aScreenReaderReadsAModulesGuide() throws {
    let face = try Self.rack()
    face.showGuide("alligator")
    let page = try #require(face.accessibility.node("help"))
    #expect(page.name.hasSuffix(": Alligator"))
    #expect(page.children.contains { $0.role == .text && $0.name == "What it does" })
    #expect(face.accessibility.node("rack.run") == nil, "the rack under it is not read")
    #expect(face.perform(.press("help.close")))
    #expect(face.guide == nil)
    #expect(face.accessibility.node("rack.run") != nil)
  }

  /// Longer than the window, it scrolls, by a wheel or a finger, and no further than its end; and
  /// a drag is a scroll rather than a press that closes it.
  @Test func aLongGuideScrolls() throws {
    let face = try Self.rack()
    face.showGuide("alligator")
    let guide = try #require(face.guide)
    try Self.draw(face)
    let room = guide.room.height
    #expect(guide.contentHeight > room, "Alligator's guide is longer than 600 points: \(guide.contentHeight)")
    face.scroll(ScrollEvent(location: SIMD2(400, 300), delta: SIMD2(0, 120)))
    #expect(guide.scroll == 120)
    face.scroll(ScrollEvent(location: SIMD2(400, 300), delta: SIMD2(0, 100_000)))
    #expect(guide.scroll == guide.contentHeight - room, "no further than its end")

    face.pointer(PointerEvent(phase: .began, location: SIMD2(790, 300)))
    face.pointer(PointerEvent(phase: .moved, location: SIMD2(790, 400)))
    face.pointer(PointerEvent(phase: .ended, location: SIMD2(790, 400)))
    #expect(face.guide != nil, "a drag, off the page or on it, scrolls and does not close it")
    #expect(guide.scroll == guide.contentHeight - room - 100)
  }
}
