import DriftboxRack
import DriftboxRackSession
import DriftboxShell
import Testing

@testable import DriftboxInterface

/// The guided tours on a drawn rack: the first offered once, a panel whose buttons skip, end and
/// choose the patch to end on, presses on it that nothing under it hears, a ring round what a step
/// points at, and the tours in the patches' menu and to a screen reader.
@MainActor
struct RackTourCoachTests {
  final class Memory: RackMemory {
    var kept: [String: Any] = [:]
    func string(forKey key: String) -> String? { kept[key] as? String }
    func set(_ value: Any?, forKey key: String) { kept[key] = value }
  }

  static func rack(memory: Memory? = Memory(), touch: Bool = false, width: Float = 1000) -> RackInterface {
    let rack = RackSession(memory: memory)
    rack.open(RackInterfaceTests.patch(), name: "Mine")
    let face = RackInterface(rack: rack)
    face.touch = touch
    face.tours = RackTour.all(for: touch ? .android : .windows)
    face.size = SIMD2(width, 700)
    return face
  }

  static func panel(_ face: RackInterface) throws -> RackInterface.TourPanel {
    try #require(face.tourPanel(face.stage))
  }

  /// The button's frame on the panel.
  static func button(_ face: RackInterface, _ button: RackInterface.TourButton) throws -> Rect {
    try #require(try panel(face).buttons.first { $0.button == button }?.frame)
  }

  static func press(_ face: RackInterface, _ button: RackInterface.TourButton) throws {
    RackInterfaceTests.press(face, RackInterfaceTests.centre(try Self.button(face, button)))
  }

  /// The first tour is offered once, to a rack that remembers: turned down, it is not offered again,
  /// even by the next rack with the same memory.
  @Test func theFirstTourIsOfferedOnce() throws {
    let memory = Memory()
    let face = Self.rack(memory: memory)
    #expect(try Self.panel(face).buttons.map(\.button) == [.take, .notNow])
    try Self.press(face, .notNow)
    #expect(face.tourPanel(face.stage) == nil)
    #expect(Self.rack(memory: memory).tourPanel(face.stage) == nil, "remembered")
    #expect(Self.rack(memory: nil).tourPanel(face.stage) == nil, "a rack that remembers nothing never offers")
  }

  /// Taking the offer starts the first tour from its own patch; Skip passes over the step; and End
  /// Tour, with a patch to go back to, asks which to keep; Back puts the rack's own back.
  @Test func theOfferTakenAndEnded() throws {
    let face = Self.rack()
    try Self.press(face, .take)
    #expect(face.rack.tourRun?.tour.id == "first-sound")
    #expect(face.rack.patch.modules.isEmpty, "its own patch")
    #expect(face.rack.tourOffered)
    #expect(try Self.panel(face).buttons.map(\.button) == [.fold, .end, .skip])

    try Self.press(face, .skip)
    #expect(face.rack.tourRun?.marks.first == .skipped)
    #expect(face.rack.tourRun?.at == 1)

    try Self.press(face, .end)
    #expect(face.rack.tourRun != nil, "a choice, not an end")
    #expect(try Self.panel(face).buttons.map(\.label) == ["Hide", "Keep This Patch", "Back to Mine"])
    try Self.press(face, .back)
    #expect(face.rack.tourRun == nil)
    #expect(face.rack.name == "Mine")
    #expect(face.rack.patch.modules.map(\.id) == ["keys", "osc", "out"])
  }

  /// A step done ticks on the panel and moves it on, as the rack sees it done; folded, the panel is
  /// its head alone.
  @Test func aStepDoneTicksAndItFolds() throws {
    let face = Self.rack()
    face.take(try #require(face.tours.first))
    let open = try Self.panel(face)
    #expect(open.checks.map(\.mark) == [.todo, .todo, .todo, .todo])
    face.rack.add("voice")
    face.rack.tick()
    #expect(try Self.panel(face).checks.map(\.mark) == [.done, .todo, .todo, .todo])
    #expect(try Self.panel(face).lines.contains { $0.text == "1 of 4" })

    try Self.press(face, .fold)
    let folded = try Self.panel(face)
    #expect(folded.frame.height < open.frame.height / 2)
    #expect(folded.checks.isEmpty && folded.buttons.map(\.button) == [.fold])
  }

  /// A press on the panel is the panel's: the module under it neither hears it nor offers its menu.
  @Test func thePanelHasThePressesOnIt() throws {
    let face = Self.rack()
    face.take(try #require(face.tours.first(where: { $0.id == "patch-by-hand" })))
    let panel = try Self.panel(face)
    let blank = SIMD2(panel.frame.x + 4, panel.frame.maxY - 4)
    let before = face.rack.patch
    RackInterfaceTests.press(face, blank, to: blank + SIMD2(0, -60))
    #expect(face.rack.patch == before)
    #expect(face.menu(at: blank) == nil)
  }

  /// The ring is round what the step points at: Add, while the step is adding; the module, once the
  /// step is about it.
  @Test func theSpotIsWhatTheStepPointsAt() throws {
    let face = Self.rack()
    face.take(try #require(face.tours.first(where: { $0.id == "patch-by-hand" })))
    let add = try #require(face.stage.chips.first { $0.target == .add })
    #expect(face.tourSpotFrame(face.stage) == add.frame)
    face.rack.add("ladder")
    face.rack.flip()
    face.rack.tick()
    face.rack.flip()
    face.rack.tick()
    #expect(face.rack.tourRun?.at == 2)
    let stage = face.stage
    let ladder = try #require(stage.faces.first { $0.module.type == "ladder" })
    #expect(face.tourSpotFrame(stage)?.x == stage.origin.x + ladder.frame.x * stage.scale)
  }

  /// A touchscreen's patches' menu has every tour, those finished ticked, and one chosen is taken.
  @Test func theToursAreInThePatchesMenu() throws {
    let face = Self.rack(touch: true, width: 390)
    let chip = try #require(face.stage.chips.first { $0.target == .patches })
    RackTouchTests.tap(face, RackInterfaceTests.centre(chip.frame))
    let menu = try #require(face.takeMenuRequest()?.menu)
    let tours = try #require(
      menu.items.compactMap { item -> Menu? in
        if case .submenu(let sub) = item, sub.title == "Rack Tours" { return sub }
        return nil
      }.first)
    #expect(tours.items.count == 5)
    face.choose("tour.make-it-move")
    #expect(face.rack.tourRun?.tour.id == "make-it-move")
    #expect(face.rack.tourRun?.tour.steps.first?.title == "ADD › Modulation › LFO.", "a touchscreen's words")
    // A phone's panel is across the top, with room for the step it is on and not the list.
    let panel = try Self.panel(face)
    #expect(panel.frame.x == RackStage.margin && panel.frame.maxX == 390 - RackStage.margin)
    #expect(panel.checks.isEmpty)
  }

  /// A screen reader is told the panel, and presses its buttons as a hand would.
  @Test func aScreenReaderHearsTheTour() throws {
    let face = Self.rack()
    face.take(try #require(face.tours.first))
    let tour = try #require(face.accessibility.children.first { $0.id == "tour" })
    #expect(tour.name == "Guided tour: A sound of your own")
    #expect(tour.children.contains { $0.name == "ADD › Sources › Voice." })
    #expect(face.perform(.press("tour.skip")))
    #expect(face.rack.tourRun?.marks.first == .skipped)
  }
}
