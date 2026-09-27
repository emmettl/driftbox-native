import DriftboxHelp
import DriftboxRack
import Testing

@testable import DriftboxRackSession

/// The guided tours: each starts from its own small patch, keeping the rack's own to go back to; its
/// steps tick themselves as they are done, in any order, and stay ticked; and one taken to the end
/// is remembered.
@MainActor
struct RackToursTests {
  final class Memory: RackMemory {
    var kept: [String: Any] = [:]
    func string(forKey key: String) -> String? { kept[key] as? String }
    func set(_ value: Any?, forKey key: String) { kept[key] = value }
  }

  static let tours = RackTour.all(for: .mac)
  static func tour(_ id: String) -> RackTour { tours.first { $0.id == id }! }

  static func take(_ id: String, memory: Memory = Memory()) -> RackSession {
    let rack = RackSession(memory: memory)
    rack.open(Patch(modules: [PatchModule(id: "vco-7", type: "vco")], cables: []), name: "Mine")
    rack.startTour(tour(id))
    return rack
  }

  static func id(_ rack: RackSession, _ type: String) -> String {
    rack.patch.modules.first { $0.type == type }!.id
  }

  static func cable(_ rack: RackSession, _ from: String, _ fromPort: String, _ to: String, _ toPort: String) {
    rack.connect(PortReference(id(rack, from), fromPort), PortReference(id(rack, to), toPort))
  }

  static func done(_ rack: RackSession) -> Bool { rack.tourRun?.finished == true }

  /// Every port and knob a step looks for is one the modules have, by those names.
  @Test func whatTheStepsLookForIsThere() {
    let ports: [(String, String, Bool)] = [
      ("lfo", "bi", false), ("ladder", "in", true), ("ladder", "cutoff", true),
      ("transport", "sixteenth", false),
      ("seq", "clock", true), ("seq", "pitch", false), ("seq", "gate", false), ("voice", "pitch", true),
      ("voice", "gate", true), ("voice", "out", false), ("ladder", "out", false), ("combi", "rotary1", false),
      ("combi", "rotary2", false),
    ]
    for (type, port, inlet) in ports {
      let def = RackModules.registry[type]
      #expect((inlet ? def?.inlets : def?.outlets)?.contains { $0.id == port } == true, "\(type).\(port)")
    }
    for (type, param) in [("lfo", "rate"), ("lfo", "shape"), ("ladder", "cutoff"), ("combi", "rotary1")] {
      #expect(RackModules.registry[type]?.params.contains { $0.id == param } == true, "\(type) \(param)")
    }
  }

  /// Five of the reference's six, the rack's automation being the web's alone, and every platform
  /// has them, in its own words.
  @Test func theToursAndTheirPatches() {
    #expect(
      Self.tours.map(\.id) == ["first-sound", "patch-by-hand", "make-it-move", "sequence-it", "macros"])
    #expect(Self.tour("first-sound").setup.modules.isEmpty)
    let byHand = Self.tour("patch-by-hand").setup
    #expect(RackTourChecks.audible(byHand, "voice") && !RackTourChecks.has(byHand, "ladder"))
    #expect(RackTourChecks.sequencedVoice(byHand), "its Voice repeats on its own")
    let moving = Self.tour("make-it-move").setup
    #expect(RackTourChecks.audible(moving, "ladder"))
    let sequenced = Self.tour("sequence-it").setup
    #expect(!RackTourChecks.has(sequenced, "seq") && !RackTourChecks.has(sequenced, "transport"))
    for platform in [HelpPlatform.mac, .windows, .android] {
      #expect(RackTour.all(for: platform).map { $0.steps.count } == [4, 5, 5, 6, 4])
    }
    #expect(RackTour.all(for: .android)[0].steps[2].title == "Tap BACK to turn the rack round.")
  }

  /// A tour starts from its patch with the rack's own kept; going back gives it back.
  @Test func theRacksOwnPatchIsKept() {
    let rack = Self.take("patch-by-hand")
    #expect(rack.name == "Your first cable" && !rack.patch.modules.contains { $0.id == "vco-7" })
    rack.closeTour(goingBack: true)
    #expect(rack.tourRun == nil && rack.name == "Mine" && rack.patch.modules.map(\.id) == ["vco-7"])
  }

  /// The first: a Voice, the keys, the back, a knob; a step done early ticks too, and a step that
  /// stops holding stays ticked.
  @Test func aSoundOfYourOwn() {
    let memory = Memory()
    let rack = Self.take("first-sound", memory: memory)
    rack.flip()
    rack.tick()
    #expect(rack.tourRun?.marks == [.todo, .todo, .done, .todo], "done out of order")
    rack.flip()
    rack.tick()
    #expect(rack.tourRun?.marks[2] == .done, "and stays done, turned back")
    _ = rack.add("voice")
    // Keys wired by hand, as a MIDI module the keys make for themselves would be.
    _ = rack.add("midi")
    Self.cable(rack, "midi", "pitch", "voice", "pitch")
    Self.cable(rack, "midi", "gate", "voice", "gate")
    rack.noteDown(60)
    rack.tick()
    rack.noteUp(60)
    rack.set(Self.id(rack, "voice"), "cutoff", to: 400)
    rack.tick()
    #expect(Self.done(rack) && rack.finishedTours == ["first-sound"])
    #expect(memory.kept[RackSession.toursKey] as? String == "first-sound")
  }

  @Test func yourFirstCable() {
    let rack = Self.take("patch-by-hand")
    _ = rack.add("ladder")
    rack.flip()
    Self.cable(rack, "voice", "out", "ladder", "in")
    Self.cable(rack, "ladder", "out", "out", "in")
    rack.set(Self.id(rack, "ladder"), "cutoff", to: 300)
    rack.tick()
    #expect(Self.done(rack))
  }

  @Test func makeItMove() {
    let rack = Self.take("make-it-move")
    _ = rack.add("lfo")
    Self.cable(rack, "lfo", "bi", "ladder", "cutoff")
    rack.set(Self.id(rack, "lfo"), "rate", to: 3)
    rack.set(Self.id(rack, "lfo"), "shape", to: 1)
    rack.tick()
    #expect(rack.tourRun?.marks.last == .todo)
    rack.setTrim(Self.id(rack, "ladder"), "cutoff", to: 0.4)
    rack.tick()
    #expect(Self.done(rack))
  }

  @Test func letItPlayItself() {
    let rack = Self.take("sequence-it")
    _ = rack.add("seq")
    _ = rack.add("transport")
    Self.cable(rack, "transport", "sixteenth", "seq", "clock")
    Self.cable(rack, "seq", "pitch", "voice", "pitch")
    Self.cable(rack, "seq", "gate", "voice", "gate")
    rack.toggleRunning()
    rack.set(Self.id(rack, "seq"), "pitch1", to: 7)
    rack.tick()
    #expect(Self.done(rack), "\(rack.tourRun?.marks ?? [])")
  }

  @Test func fourKnobsThatPlayThePatch() throws {
    let rack = Self.take("macros")
    _ = rack.add("combi")
    let combi = Self.id(rack, "combi")
    let ladder = Self.id(rack, "ladder")
    rack.addRoute(combi)
    rack.setRoute(0) { $0.to = PortReference(ladder, "cutoff") }
    rack.addRoute(combi)
    rack.set(combi, "rotary1", to: 0.8)
    rack.tick()
    #expect(Self.done(rack), "\(rack.tourRun?.marks ?? [])")
  }

  /// A step passed over is skipped, not done, and the tour moves on; done later, it ticks after all.
  @Test func aSkippedStepCanStillBeDone() {
    let rack = Self.take("first-sound")
    rack.skipTourStep()
    #expect(rack.tourRun?.marks.first == .skipped && rack.tourRun?.at == 1)
    _ = rack.add("voice")
    rack.tick()
    #expect(rack.tourRun?.marks.first == .done)
    #expect(rack.tourRun?.at == 1, "never back")
  }
}
