import DriftboxHostAndroid
import Testing

struct MIDIPortNamingTests {
  @Test func aSecondDeviceOfTheSameNameIsNumbered() {
    #expect(MIDIPortNaming.unique("Keystep", among: []) == "Keystep")
    #expect(MIDIPortNaming.unique("Keystep", among: ["Keystep"]) == "Keystep 2")
    #expect(MIDIPortNaming.unique("Keystep", among: ["Keystep", "Keystep 2"]) == "Keystep 3")
  }

  @Test func aDeviceWithOnePortIsKnownByItsName() {
    #expect(MIDIPortNaming.port(0, of: 1, on: "Keystep") == "Keystep")
  }

  @Test func aDeviceWithMorePortsNumbersThemFromOne() {
    #expect(MIDIPortNaming.port(0, of: 2, on: "MIDISport") == "MIDISport port 1")
    #expect(MIDIPortNaming.port(1, of: 2, on: "MIDISport") == "MIDISport port 2")
  }
}
