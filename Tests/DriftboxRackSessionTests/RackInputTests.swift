import DriftboxHost
import DriftboxRack
import Foundation
import Testing

@testable import DriftboxRackSession

/// What the Audio Input module hears: the platform's input, open while a patch has the module and
/// the rack is sounding, and let go of otherwise; the device chosen, and remembered.
@MainActor
struct RackInputTests {
  /// Somewhere to listen that keeps track of what it was asked.
  final class Microphones: AudioCapturing {
    var chosen: String? { didSet { onChange?() } }
    var devices = [AudioDevice(id: "{mic}", name: "Microphone"), AudioDevice(id: "{usb}", name: "Interface")]
    var current: AudioDevice? {
      destination == nil ? nil : devices.first { $0.id == chosen } ?? systemDefault
    }
    var systemDefault: AudioDevice? { devices.first }
    var error: String?
    var onChange: (() -> Void)?
    var destination: LiveInput? {
      didSet {
        if destination != nil && oldValue == nil { opened += 1 }
        onChange?()
      }
    }
    var opened = 0
  }

  static let liveWire = "guitar-pedalboard"

  @Test func itListensOnlyWhileThePatchHasAnAudioInput() throws {
    let microphones = Microphones()
    let rack = RackSession(audio: RackPortsTests.Speakers(), input: microphones)
    #expect(rack.takesInput)
    #expect(microphones.destination == nil, "the first patch has no Audio Input")

    rack.open(try #require(PatchEntry.all.first { $0.id == Self.liveWire }))
    #expect(microphones.destination === rack.host.input)
    #expect(rack.hearing?.name == "Microphone")

    // An edit to the patch keeps the device open rather than opening it again.
    rack.set("input-1", "level", to: 0.5)
    #expect(microphones.opened == 1)

    rack.remove("input-1")
    #expect(microphones.destination == nil)
    #expect(rack.hearing == nil)
    rack.undo()
    #expect(microphones.destination === rack.host.input)
    rack.close()
    #expect(microphones.destination == nil, "closed, it lets go")
    #expect(!RackSession().takesInput)
  }

  /// Asleep, nothing renders the host, so nothing listens either, until it is woken.
  @Test func asleepItDoesNotListen() throws {
    let microphones = Microphones()
    let rack = RackSession(audio: RackPortsTests.Speakers(), input: microphones, awake: false)
    rack.open(try #require(PatchEntry.all.first { $0.id == Self.liveWire }))
    #expect(microphones.destination == nil)
    rack.wake()
    #expect(microphones.destination === rack.host.input)
  }

  /// The device chosen is the input's, and remembered with its name between launches.
  @Test func theChoiceIsRemembered() throws {
    let suite = "rack-input-tests-\(UUID().uuidString)"
    let memory = try #require(UserDefaults(suiteName: suite))
    defer { memory.removePersistentDomain(forName: suite) }
    let microphones = Microphones()
    let rack = RackSession(input: microphones, memory: memory)
    #expect(rack.inputs.map(\.name) == ["Microphone", "Interface"])
    #expect(rack.systemInput?.id == "{mic}")
    rack.inputDevice = "{usb}"
    #expect(microphones.chosen == "{usb}")
    #expect(rack.inputDeviceName == "Interface")

    let later = Microphones()
    later.devices = []
    let again = RackSession(input: later, memory: memory)
    #expect(again.inputDevice == "{usb}")
    #expect(later.chosen == "{usb}")
    #expect(again.inputDeviceName == "Interface", "named while it is not plugged in")
    again.inputDevice = nil
    #expect(RackSession(input: Microphones(), memory: memory).inputDevice == nil)
  }
}
