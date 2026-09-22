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

  /// The other direction: what Driftbox sends when it is the clock. Held to the reference on
  /// the awkward cases as much as the ordinary ones — a fractional step, a negative one, a
  /// step length of zero, and a position past the fourteen bits the message has room for.
  struct OutEntry: Decodable {
    struct Message: Decodable, Equatable {
      let message: String
      let step: Double?
      let time: Double?
    }
    let call: String
    let step: Double?
    let time: Double?
    let seconds: Double?
    let message: Message?
    let result: [Message]?
    let bytes: [UInt8]?

    enum CodingKeys: String, CodingKey {
      case call, step, time, seconds, message, result
    }

    init(from decoder: Decoder) throws {
      let box = try decoder.container(keyedBy: CodingKeys.self)
      call = try box.decode(String.self, forKey: .call)
      step = try box.decodeIfPresent(Double.self, forKey: .step)
      time = try box.decodeIfPresent(Double.self, forKey: .time)
      seconds = try box.decodeIfPresent(Double.self, forKey: .seconds)
      message = try box.decodeIfPresent(Message.self, forKey: .message)
      // `result` is a list of messages for the schedulers and a list of bytes for `clockBytes`.
      if call == "bytes" {
        bytes = try box.decode([UInt8].self, forKey: .result)
        result = nil
      } else {
        result = try box.decode([Message].self, forKey: .result)
        bytes = nil
      }
    }
  }

  static func named(_ message: ClockMessage) -> (String, Double?) {
    switch message {
    case .tick: ("tick", nil)
    case .start: ("start", nil)
    case .continue: ("continue", nil)
    case .stop: ("stop", nil)
    case .position(let step): ("position", Double(step))
    }
  }

  @Test func sendsTheClockAsTheReferenceDoes() throws {
    let entries = try JSONDecoder().decode([OutEntry].self, from: Fixtures.data("midi-clock-out.json"))
    #expect(entries.count == 28)
    for (index, entry) in entries.enumerated() {
      switch entry.call {
      case "start":
        // The reference floors its step; a `Double` comes in so the port can be held to that.
        let scheduled = scheduleClockStart(step: Int((entry.step ?? 0).rounded(.down)), at: 12.5)
        let expected = try #require(entry.result)
        #expect(scheduled.count == expected.count, "start \(index)")
        for (made, want) in zip(scheduled, expected) {
          let (name, step) = Self.named(made.message)
          #expect(name == want.message, "start \(index)")
          #expect(step == want.step, "start \(index) step")
          #expect(made.time == want.time, "start \(index) time")
        }
      case "step":
        let scheduled = scheduleClockStep(at: entry.time ?? 0, stepSeconds: entry.seconds ?? 0)
        let expected = try #require(entry.result)
        #expect(scheduled.count == expected.count, "step \(index)")
        for (made, want) in zip(scheduled, expected) {
          #expect(Self.named(made.message).0 == want.message, "step \(index)")
          #expect(made.time == want.time, "step \(index) time")
        }
      default:
        let message = try #require(entry.message)
        let made: ClockMessage =
          switch message.message {
          case "tick": .tick
          case "start": .start
          case "continue": .continue
          case "stop": .stop
          default: .position(step: Int((message.step ?? 0).rounded(.down)))
          }
        #expect(made.bytes == entry.bytes, "bytes \(index)")
      }
    }
  }
}
