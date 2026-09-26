import DriftboxInterface
import DriftboxSeq
import DriftboxSession
import DriftboxShell
import Foundation
import Testing

/// The groovebox's controls as a screen reader is told them, and what it asks done as a hand would
/// do it: the transport, the tempo, the steps, the 303's notes and the knobs.
@MainActor
struct InterfaceAccessibilityTests {
  static func node(_ interface: Interface, _ id: String) throws -> AccessibilityNode {
    try #require(interface.accessibility.node(id), "no \(id)")
  }

  /// The bar's transport by what each does, with its state; the song and where it has got to; the
  /// tempo as a slider in its own words; and every control's id unique.
  @Test func theTransportIsDescribed() throws {
    let interface = try InterfaceTests.interface()
    let root = interface.accessibility
    let ids = root.flattened.map(\.id)
    #expect(Set(ids).count == ids.count, "each id once")

    let play = try Self.node(interface, "transport.play")
    #expect(play.role == .toggle && play.name == "Play" && play.isOn == false)
    #expect(try Self.node(interface, "transport.top").role == .button)
    #expect(try Self.node(interface, "transport.loop").isOn == false)
    let tempo = try Self.node(interface, "number.tempo")
    #expect(tempo.role == .slider && tempo.name == "Tempo" && tempo.current == 120 && tempo.range == 20...300)
    #expect(tempo.value?.isEmpty == false)
    #expect(try Self.node(interface, "song.position").value == "Bar 1, step 1 of 16")
    #expect(try Self.node(interface, "bar").children.allSatisfy { $0.frame.z > 0 && $0.frame.w > 0 })
  }

  /// Each lane a group of its steps, each on, off or accented as the pattern has it; pressed, a step
  /// turns over as a click turns it.
  @Test func theStepsAreDescribedAndSet() throws {
    let interface = try InterfaceTests.interface()
    let lane = try Self.node(interface, "lane.909.bd")
    #expect(lane.role == .group && lane.children.filter { $0.role == .toggle }.count == 16)
    let first = try Self.node(interface, "lane.909.bd.step.1")
    #expect(first.isOn == true && first.value == "on")
    #expect(try Self.node(interface, "lane.909.bd.step.2").isOn == false)

    #expect(interface.perform(.press("lane.909.bd.step.2")))
    #expect(interface.session.song?.patterns.first?.step("909.bd", at: 1) != .off)
    #expect(try Self.node(interface, "lane.909.bd.step.2").isOn == true, "told as it is now")
    #expect(!interface.perform(.press("lane.nowhere.step.1")), "nothing there")
  }

  /// A slider set is one turn of it, heard and undone as one; stepped, it moves a notch; and a toggle
  /// is pressed, not set.
  @Test func aSliderIsSetAndStepped() throws {
    let interface = try InterfaceTests.interface()
    #expect(interface.perform(.set("number.tempo", 128.4)))
    #expect(interface.session.song?.bpm == 128)
    #expect(interface.session.canUndo)
    #expect(interface.perform(.increment("number.tempo")))
    #expect(interface.session.song?.bpm == 129)
    #expect(interface.perform(.decrement("number.tempo")))
    #expect(interface.perform(.decrement("number.tempo")))
    #expect(interface.session.song?.bpm == 127)
    #expect(interface.perform(.set("number.tempo", 1000)))
    #expect(interface.session.song?.bpm == 300, "kept to its range")
  }

  /// A voice's knobs, once it is showing, each named for the voice and what it turns; set, the song
  /// has it.
  @Test func theKnobsShowingAreDescribed() throws {
    let interface = try InterfaceTests.interface()
    #expect(interface.perform(.press("lane.909.bd.select")))
    let panel = try Self.node(interface, "inspector")
    let knobs = panel.children.filter { $0.role == .slider }
    #expect(!knobs.isEmpty)
    let knob = try #require(knobs.first)
    #expect(knob.name.hasPrefix(panel.name.split(separator: " ").dropFirst().joined(separator: " ")))
    let range = try #require(knob.range)
    #expect(interface.perform(.set(knob.id, range.upperBound)))
    #expect(try Self.node(interface, knob.id).current == range.upperBound)
    #expect(interface.perform(.press("inspector.close")))
    #expect(interface.accessibility.node("inspector") == nil)
  }

  /// A 303 step's note set as a slider, and its accent turned on.
  @Test func aBassStepIsSet() throws {
    var song = InterfaceTests.song()
    song.patterns[0].bass["303.a"] = [BassStep](repeating: .rest, count: 16)
    let interface = try InterfaceTests.interface(song)
    let line = try #require(interface.accessibility.children.first { $0.id.hasPrefix("line.") })
    let step = try #require(line.children.first { $0.id == "\(line.id).step.1" })
    #expect(step.role == .slider && step.value == "rest")
    #expect(interface.perform(.set(step.id, 7)))
    let set = try Self.node(interface, step.id)
    #expect(set.current == 7 && set.value == "G1")
    #expect(interface.perform(.press("\(step.id).accent")))
    #expect(try Self.node(interface, "\(step.id).accent").isOn == true)
  }

  /// With the controls put away, only word of where they went.
  @Test func withTheControlsAwayThereIsLittleToSay() throws {
    let interface = try InterfaceTests.interface()
    interface.isShowing = false
    #expect(interface.accessibility.children.map(\.id) == ["hidden"])
  }
}
