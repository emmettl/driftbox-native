import DriftboxHost
import DriftboxInterface
import DriftboxRack
import DriftboxRackSession
import DriftboxSession
import DriftboxShell
import Testing

@testable import DriftboxTouch

/// The guides on a touch screen: the groovebox's from the song's menu, the rack's from the patch's,
/// each a sheet over the screen that has every finger while it is open.
@MainActor
struct TouchscreenHelpTests {
  static func centre(_ rect: Rect) -> SIMD2<Float> {
    SIMD2(rect.x + rect.width / 2, rect.y + rect.height / 2)
  }

  static func tap(_ screen: Touchscreen, _ at: SIMD2<Float>) {
    screen.touch(TouchscreenTests.finger(.began, 1, at))
    screen.touch(TouchscreenTests.finger(.ended, 1, at))
  }

  /// The song's chip offers the groovebox's guide; chosen, it covers the screen, a finger on it is not
  /// the pad's nor a long press's, and its Close puts it away.
  @Test func theSongsMenuOffersTheGuide() throws {
    guard let screen = try TouchscreenTests.screen() else { return }
    let chip = try #require(screen.interface.layout.songChip)
    var shown: Menu?
    screen.onMenu = { menu, _ in shown = menu }
    Self.tap(screen, Self.centre(chip.frame))
    #expect(shown?.commands.last?.title == "Groovebox Guide")
    screen.choose("help.groovebox")
    let guide = try #require(screen.interface.guide)
    #expect(guide.title == "Groovebox guide")
    #expect(screen.interface.accessibility.node("help") != nil)

    // A finger resting on it asks for no menu, and one on it presses nothing under it.
    shown = nil
    let open = try #require(TouchscreenTests.open(screen))
    var now = 0.0
    screen.clock = { now }
    screen.touch(TouchscreenTests.finger(.began, 2, SIMD2(186, 400)))
    now = 1
    screen.checkLongPress()
    screen.touch(TouchscreenTests.finger(.ended, 2, SIMD2(186, 400)))
    #expect(shown == nil)
    #expect(screen.session.padTouch == nil)
    #expect(screen.interface.guide != nil)

    // Its Close puts it away, and the pad is the pad again.
    let close = try #require(guide.accessibility.node("help.close")).frame
    Self.tap(screen, SIMD2(close.x + close.z / 2, close.y + close.w / 2))
    #expect(screen.interface.guide == nil)
    screen.touch(TouchscreenTests.finger(.began, 3, open))
    #expect(screen.session.padTouch != nil)
    screen.touch(TouchscreenTests.finger(.ended, 3, open))
  }

  /// The patch's chip offers the rack's guide, written for fingers.
  @Test func thePatchsMenuOffersTheRacksGuide() throws {
    guard let screen = try TouchscreenTests.screen() else { return }
    let rack = RackSession()
    rack.open(Patch(modules: [PatchModule(id: "out", type: "out")], cables: []), name: "Out")
    screen.add(rack)
    screen.show(rack: true)
    let face = try #require(screen.rack)
    face.size = screen.interface.size
    let chip = try #require(face.stage.chips.first { $0.target == .patches })
    var shown: Menu?
    screen.onMenu = { menu, _ in shown = menu }
    Self.tap(screen, Self.centre(chip.frame))
    #expect(shown?.commands.contains { $0.id == "help.rack" } == true)
    screen.choose("help.rack")
    #expect(face.guide?.title == "Rack guide")
    #expect(face.guide?.guide.topics.count == 6)
    #expect(face.menu(at: SIMD2(186, 400)) == nil, "no module's menu while it is open")
  }
}
