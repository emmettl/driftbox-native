#if canImport(AVFoundation)
  import DriftboxRack
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// MIDI into the rack: the reference's decoding, byte for byte, and each channel reaching only
  /// the modules listening on it.
  @MainActor
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

    /// Two keyboards on two channels, each through a gate of its own: a note on one channel opens
    /// only its own, and holding one does not steal the other's single voice.
    @Test func eachChannelPlaysItsOwnModules() {
      func voice(_ n: Int) -> [PatchModule] {
        [
          PatchModule(id: "keys\(n)", type: "midi", params: ["channel": Double(n)]),
          PatchModule(id: "osc\(n)", type: "vco"),
          PatchModule(id: "amp\(n)", type: "vca", params: ["gain": 0]),
          PatchModule(id: "out\(n)", type: "out"),
        ]
      }
      func wires(_ n: Int) -> [PatchCable] {
        [
          PatchCable(from: PortReference("keys\(n)", "pitch"), to: PortReference("osc\(n)", "pitch")),
          PatchCable(from: PortReference("osc\(n)", "out"), to: PortReference("amp\(n)", "in")),
          PatchCable(from: PortReference("keys\(n)", "gate"), to: PortReference("amp\(n)", "cv")),
          PatchCable(from: PortReference("amp\(n)", "out"), to: PortReference("out\(n)", "in")),
        ]
      }
      let model = RackModel()
      model.open(Patch(modules: voice(1) + voice(2), cables: wires(1) + wires(2)), name: "Two")
      model.listen()
      let frames = 4800
      let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
      let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
      defer {
        left.deallocate()
        right.deallocate()
      }
      func loud() -> Bool {
        model.host.render(frames: frames, left: left, right: right)
        return (0..<frames).contains { abs(left[$0]) > 0.01 }
      }
      #expect(!loud())
      model.midi([0x91, 48, 100])
      #expect(loud())
      model.midi([0x81, 48, 0])
      _ = loud()
      #expect(!loud())
      // One voice a channel, and a note on each: both sound, neither steals.
      model.midi([0x90, 48, 100])
      model.midi([0x91, 55, 100])
      #expect(model.sounding.sorted() == [48, 55])
      // Channel 3 has nobody listening.
      model.midi([0x92, 60, 100])
      model.midi([0xB0, 123, 0])
      #expect(model.sounding.sorted() == [55, 60])
      model.allNotesOff()
      #expect(model.sounding.isEmpty)
    }
  }
#endif
