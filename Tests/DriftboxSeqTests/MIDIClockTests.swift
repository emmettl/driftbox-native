import ConformanceSupport
import DriftboxSeq
import Foundation
import Testing

/// A synthetic clock stream — jitter, a tempo change, a lost tick, stop, position, continue, a
/// stall — through the follower and the follow rules, against what the reference made of it.
struct MIDIClockTests {
  struct Entry: Decodable {
    struct Command: Decodable {
      let bpm: Double?
      let transport: String?
      let step: Int?
    }
    struct State: Decodable {
      let bpm: Double?
      let running: Bool
      let ticks: Int
    }
    let time: Double
    let bytes: [UInt8]
    let command: Command
    let state: State
    let step: Int
  }

  @Test func followsTheClockAsTheReferenceDoes() throws {
    let trace = try JSONDecoder().decode([Entry].self, from: Fixtures.data("midi-clock.json"))
    #expect(trace.count > 400)
    var follower = ClockFollower()
    var local = LocalClockState(bpm: 120, ticks: 0, time: 1000)
    var tempoChanges = 0
    for (index, entry) in trace.enumerated() {
      let message = try #require(ClockMessage(bytes: entry.bytes))
      let command = followClock(message, at: entry.time, follower: &follower, local: local)
      if let bpm = command.bpm {
        local.bpm = bpm
        tempoChanges += 1
      }
      local.ticks = (local.ticks ?? 0) + (entry.time - (local.time ?? entry.time)) * local.bpm * 24 / 60000
      local.time = entry.time

      #expect(command.bpm == entry.command.bpm, "message \(index): bpm")
      let transport: String? =
        switch command.transport {
        case .start: "start"
        case .resume: "resume"
        case .stop: "stop"
        case nil: nil
        }
      #expect(transport == entry.command.transport, "message \(index): transport")
      #expect(command.step == entry.command.step, "message \(index): step")
      #expect(follower.state.bpm == entry.state.bpm, "message \(index): estimate")
      #expect(
        follower.state.running == entry.state.running && follower.state.ticks == entry.state.ticks,
        "message \(index): state")
      #expect(follower.step == entry.step, "message \(index): step")
    }
    #expect(tempoChanges > 50)
  }

  @Test func messagesRoundTripThroughTheirBytes() {
    for message in [ClockMessage.tick, .start, .stop, .continue, .position(step: 32), .position(step: 20000)]
    {
      let parsed = ClockMessage(bytes: message.bytes)
      if case .position(let step) = message, step > 0x3FFF {
        #expect(parsed == .position(step: 0x3FFF))
      } else {
        #expect(parsed == message)
      }
    }
    #expect(ClockMessage(bytes: [0x90, 60, 100]) == nil)
    #expect(ClockMessage(bytes: [0xF2]) == nil)
  }
}
