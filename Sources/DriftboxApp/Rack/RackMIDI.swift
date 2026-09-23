#if canImport(SwiftUI) && canImport(AVFoundation)
  import Foundation

  /// What a MIDI channel message means to the rack: the reference's `midiPerformance` and the
  /// handler around it in `openMidi`, as pure arithmetic on the bytes.
  enum RackMIDI {
    /// A controller with an outlet of its own on the MIDI module.
    enum Control: String, CaseIterable {
      case mod, bend, aftertouch, expression, breath, sustain
    }

    enum Event: Equatable {
      case down(note: Int, velocity: Double, channel: Int)
      case up(note: Int, channel: Int)
      case performance(Control, value: Double, channel: Int)
      /// Every controller, the ones above included, for learning onto a knob.
      case control(Int, value: Int, channel: Int)
      /// CC 123: what a panic button sends.
      case allOff(channel: Int)
    }

    /// A controller, pressure or bend as a performance value: the mod wheel, breath and
    /// expression 0...1, sustain on or off at 64, pressure 0...1 whether per key or per channel,
    /// and bend −1...1 with its centre at 8192.
    static func performance(_ bytes: [UInt8]) -> (control: Control, value: Double, channel: Int)? {
      guard bytes.count >= 2 else { return nil }
      let status = bytes[0] & 0xF0
      let channel = Int(bytes[0] & 0x0F) + 1
      switch status {
      case 0xB0:
        let raw = bytes.count >= 3 ? Int(bytes[2] & 0x7F) : 0
        let value = Double(raw) / 127
        switch bytes[1] & 0x7F {
        case 1: return (.mod, value, channel)
        case 2: return (.breath, value, channel)
        case 11: return (.expression, value, channel)
        case 64: return (.sustain, raw >= 64 ? 1 : 0, channel)
        default: return nil
        }
      case 0xD0: return (.aftertouch, Double(bytes[1] & 0x7F) / 127, channel)
      case 0xA0 where bytes.count >= 3: return (.aftertouch, Double(bytes[2] & 0x7F) / 127, channel)
      case 0xE0 where bytes.count >= 3:
        let raw = Int(bytes[1] & 0x7F) | (Int(bytes[2] & 0x7F) << 7)
        return (.bend, raw >= 8192 ? Double(raw - 8192) / 8191 : Double(raw - 8192) / 8192, channel)
      default: return nil
      }
    }

    /// Everything one message says, in the order the reference acts on it: a controller is a
    /// performance value and learnable too; a note-on of velocity zero is a note-off, since older
    /// gear sends only that.
    static func events(_ bytes: [UInt8]) -> [Event] {
      guard bytes.count >= 2 else { return [] }
      let status = bytes[0] & 0xF0
      let channel = Int(bytes[0] & 0x0F) + 1
      let data2 = bytes.count >= 3 ? bytes[2] : 0
      var events: [Event] = []
      if let performance = performance(bytes) {
        events.append(
          .performance(performance.control, value: performance.value, channel: performance.channel))
        if status != 0xB0 { return events }
      }
      switch status {
      case 0x90 where data2 > 0:
        events.append(.down(note: Int(bytes[1]), velocity: Double(data2) / 127, channel: channel))
      case 0x80, 0x90:
        events.append(.up(note: Int(bytes[1]), channel: channel))
      case 0xB0:
        if bytes[1] == 123 { events.append(.allOff(channel: channel)) }
        events.append(.control(Int(bytes[1]), value: Int(data2), channel: channel))
      default:
        break
      }
      return events
    }
  }
#endif
