import Foundation
import Testing

@testable import DriftboxRackSession

/// MIDI into the rack: the reference's decoding, byte for byte.
struct RackMIDITests {
  @Test func controllersArePerformanceValuesAsTheReferenceReadsThem() {
    func read(_ bytes: [UInt8]) -> (RackMIDI.Control, Double, Int)? {
      RackMIDI.performance(bytes).map { ($0.control, $0.value, $0.channel) }
    }
    #expect(read([0xB2, 1, 127])! == (.mod, 1, 3))
    #expect(read([0xB0, 2, 64])! == (.breath, 64 / 127, 1))
    #expect(read([0xBF, 11, 32])! == (.expression, 32 / 127, 16))
    #expect(read([0xB0, 64, 63])! == (.sustain, 0, 1))
    #expect(read([0xB0, 64, 64])! == (.sustain, 1, 1))
    #expect(read([0xD4, 96])! == (.aftertouch, 96 / 127, 5))
    #expect(read([0xA0, 60, 48])! == (.aftertouch, 48 / 127, 1))
    #expect(read([0xE0, 0, 0])! == (.bend, -1, 1))
    #expect(read([0xE0, 0, 64])! == (.bend, 0, 1))
    #expect(read([0xE0, 127, 127])! == (.bend, 1, 1))
    #expect(read([0x90, 60, 100]) == nil)
    #expect(read([0xB0, 74, 100]) == nil)
  }

  @Test func aMessageIsEverythingItSays() {
    #expect(RackMIDI.events([0x91, 60, 127]) == [.down(note: 60, velocity: 1, channel: 2)])
    // A note-on of velocity zero is a note-off: older gear sends nothing else.
    #expect(RackMIDI.events([0x90, 60, 0]) == [.up(note: 60, channel: 1)])
    #expect(RackMIDI.events([0x80, 60, 64]) == [.up(note: 60, channel: 1)])
    // The mod wheel moves its outlet and can be learned; bend is only bend.
    #expect(
      RackMIDI.events([0xB0, 1, 127]) == [
        .performance(.mod, value: 1, channel: 1), .control(1, value: 127, channel: 1),
      ])
    #expect(RackMIDI.events([0xE0, 0, 64]) == [.performance(.bend, value: 0, channel: 1)])
    #expect(RackMIDI.events([0xB3, 123, 0]) == [.allOff(channel: 4), .control(123, value: 0, channel: 4)])
    #expect(RackMIDI.events([0xB0, 74, 20]) == [.control(74, value: 20, channel: 1)])
    #expect(RackMIDI.events([0xF8]).isEmpty)
  }
}
