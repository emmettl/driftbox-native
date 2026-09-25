import DriftboxRack
import Foundation

/// What a MIDI channel message means to the rack: the reference's `midiPerformance` and the
/// handler around it in `openMidi`, as pure arithmetic on the bytes.
public enum RackMIDI {
  /// A controller with an outlet of its own on the MIDI module.
  public enum Control: String, CaseIterable, Sendable {
    case mod, bend, aftertouch, expression, breath, sustain
  }

  public enum Event: Equatable, Sendable {
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
  public static func performance(_ bytes: [UInt8]) -> (control: Control, value: Double, channel: Int)? {
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
  public static func events(_ bytes: [UInt8]) -> [Event] {
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

/// Which knob on the desk moves which knob in the rack: the reference's `midi-cc.ts`. Learnt,
/// not a fixed table of controller numbers, so it works with whatever is plugged in; and kept
/// beside the patch rather than in it, because a binding describes the box on somebody's desk
/// and a patch travels to people who do not have that box.
public enum RackCC {
  public struct Binding: Equatable, Sendable {
    /// Controller number, 0...127.
    public var cc: Int
    /// 1...16, or 0 for any: a controller's knobs and keys are often on different channels, and
    /// somebody who has just turned a knob to teach it should not have to know which listened.
    public var channel = 0
    public var module: String
    public var param: String

    public init(cc: Int, channel: Int = 0, module: String, param: String) {
      self.cc = cc
      self.channel = channel
      self.module = module
      self.param = param
    }
  }

  public static let key = "midi.cc"

  /// One binding per target, and a controller may drive several: teaching a target a new
  /// controller replaces the old one, which would otherwise go on moving it invisibly.
  public static func learn(_ bindings: [Binding], _ binding: Binding) -> [Binding] {
    bindings.filter { !($0.module == binding.module && $0.param == binding.param) } + [binding]
  }

  public static func forget(_ bindings: [Binding], module: String, param: String) -> [Binding] {
    bindings.filter { !($0.module == module && $0.param == param) }
  }

  /// Everything a module has learnt, by param.
  public static func bindings(_ bindings: [Binding], for module: String) -> [String: Binding] {
    var out: [String: Binding] = [:]
    for binding in bindings where binding.module == module { out[binding.param] = binding }
    return out
  }

  /// What a controller message should move. A binding on channel 0 hears every channel.
  public static func targets(_ bindings: [Binding], cc: Int, channel: Int) -> [Binding] {
    bindings.filter { $0.cc == cc && ($0.channel == 0 || $0.channel == channel) }
  }

  /// A controller's 0...127 in a param's own units, rounded onto a stepped one so a selector
  /// lands on a choice.
  public static func value(_ raw: Int, _ param: ParamDef) -> Double {
    let clamped = Double(max(0, min(127, raw)))
    let value = param.min + clamped / 127 * (param.max - param.min)
    return param.stepped ? RackDisplay.jsRound(value) : value
  }

  /// `CC 74`, or `CC 74 ch3`: short, because it sits under a knob.
  public static func describe(_ binding: Binding) -> String {
    binding.channel == 0 ? "CC \(binding.cc)" : "CC \(binding.cc) ch\(binding.channel)"
  }

  /// What was learnt. Anything unreadable is no bindings, and one bad entry costs only itself.
  public static func load(_ memory: (any RackMemory)?) -> [Binding] {
    guard let text = memory?.string(forKey: key),
      let entries = try? JSONDecoder().decode([Entry].self, from: Data(text.utf8))
    else { return [] }
    return entries.compactMap { entry in
      guard let cc = entry.cc, (0...127).contains(cc),
        let channel = entry.channel, (0...16).contains(channel),
        let module = entry.module, !module.isEmpty,
        let param = entry.param, !param.isEmpty
      else { return nil }
      return Binding(cc: cc, channel: channel, module: module, param: param)
    }
  }

  public static func save(_ bindings: [Binding], to memory: (any RackMemory)?) {
    guard let memory else { return }
    let entries = bindings.map { Entry(cc: $0.cc, channel: $0.channel, module: $0.module, param: $0.param) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(entries), let text = String(data: data, encoding: .utf8)
    else { return }
    memory.set(text, forKey: key)
  }

  /// A binding as it is kept, each part read on its own: an entry that is not an object, or has a
  /// part of the wrong kind, is an entry of nothing rather than a list that cannot be read.
  private struct Entry: Codable {
    var cc: Int?
    var channel: Int?
    var module: String?
    var param: String?

    init(cc: Int, channel: Int, module: String, param: String) {
      self.cc = cc
      self.channel = channel
      self.module = module
      self.param = param
    }

    init(from decoder: any Decoder) throws {
      guard let entry = try? decoder.container(keyedBy: CodingKeys.self) else { return }
      cc = try? entry.decode(Int.self, forKey: .cc)
      channel = try? entry.decode(Int.self, forKey: .channel)
      module = try? entry.decode(String.self, forKey: .module)
      param = try? entry.decode(String.self, forKey: .param)
    }
  }
}
