import DriftboxHost
import DriftboxInterface
import DriftboxRack
import DriftboxRackSession
import DriftboxSeq
import DriftboxSession
import DriftboxShell
import Testing

@testable import DriftboxTouch

/// Undo on a touch screen, which has no Edit menu: in the song's menu, and in the patches' while the
/// rack shows, each named for what it takes back.
@MainActor
struct TouchscreenUndoTests {
  /// The menu a tap on `frame`'s middle shows.
  static func menu(tapping frame: Rect, on screen: Touchscreen) throws -> Menu {
    let at = SIMD2(frame.x + frame.width / 2, frame.y + frame.height / 2)
    var shown: Menu?
    screen.onMenu = { menu, _ in shown = menu }
    screen.touch(TouchscreenTests.finger(.began, 1, at))
    screen.touch(TouchscreenTests.finger(.ended, 1, at))
    return try #require(shown)
  }

  static func songMenu(_ screen: Touchscreen) throws -> Menu {
    try menu(tapping: try #require(screen.interface.layout.songChip).frame, on: screen)
  }

  static func title(_ id: String, in menu: Menu) -> String? {
    menu.commands.first { $0.id == id }?.title
  }

  @Test func theSongsMenuUndoesAndRedoesTheLastEdit() throws {
    guard let screen = try TouchscreenTests.screen(), let lane = screen.interface.layout.lanes.first else {
      return
    }
    let session = screen.session
    let untouched = try Self.songMenu(screen)
    #expect(Self.title("edit.undo", in: untouched) == "Undo")
    #expect(!screen.menuIsEnabled("edit.undo") && !screen.menuIsEnabled("edit.redo"), "nothing to undo yet")

    let before = session.song
    session.editShown("Set Step") { $0.cyclingStep(lane.voice.id, at: 0) }
    let edited = session.song
    let menu = try Self.songMenu(screen)
    #expect(Self.title("edit.undo", in: menu) == "Undo Set Step")
    #expect(screen.menuIsEnabled("edit.undo") && !screen.menuIsEnabled("edit.redo"))
    screen.choose("edit.undo")
    #expect(session.song == before, "the step as it was")

    let undone = try Self.songMenu(screen)
    #expect(Self.title("edit.redo", in: undone) == "Redo Set Step")
    #expect(screen.menuIsEnabled("edit.redo"))
    screen.choose("edit.redo")
    #expect(session.song == edited, "and set again")
  }

  @Test func thePatchesMenuUndoesTheRacksEdits() throws {
    guard let (screen, rack) = try TouchscreenRackTests.screen(), let face = screen.rack else { return }
    screen.show(rack: true)
    face.size = SIMD2(372, 828)
    let modules = rack.patch.modules.count
    rack.add("vco")
    let added = rack.patch.modules.count
    #expect(added > modules)

    let chip = try #require(face.stage.chips.first { $0.target == .patches })
    let menu = try Self.menu(tapping: chip.frame, on: screen)
    #expect(Self.title("edit.undo", in: menu) == rack.undoTitle && rack.undoTitle != "Undo")
    #expect(screen.menuIsEnabled("edit.undo") && !screen.menuIsEnabled("edit.redo"))
    screen.choose("edit.undo")
    #expect(rack.patch.modules.count == modules, "what was added taken out again")
    #expect(!screen.session.canUndo, "and the song's history left alone")

    let undone = try Self.menu(tapping: chip.frame, on: screen)
    #expect(Self.title("edit.redo", in: undone) == rack.redoTitle)
    screen.choose("edit.redo")
    #expect(rack.patch.modules.count == added)
  }
}
