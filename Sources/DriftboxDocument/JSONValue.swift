/// JSON, parsed into values that keep their keys in order and written back the way
/// `JSON.stringify` writes it.
///
/// Foundation has a JSON parser and this is not it, for two reasons that are both about the
/// format being shared with a JavaScript program. Object keys must stay in document order — it is
/// the order voices are planned in — and Foundation hands back a dictionary. And a document has
/// to be written back byte for byte, which means JavaScript's number formatting and no other.
public enum JSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object(JSONObject)
}

/// An object's members, in order. A repeated key keeps its first position and its last value,
/// as `JSON.parse` does.
///
/// One difference from JavaScript is left in: there, keys that look like array indices ("0",
/// "12") iterate before all others, in numeric order. No Driftbox document has such keys — they
/// are voice ids and field names — so document order is kept as it is.
public struct JSONObject: Equatable, Sendable {
  public private(set) var members: [(key: String, value: JSONValue)] = []

  public init() {}

  public subscript(key: String) -> JSONValue? {
    get { members.first { $0.key == key }?.value }
    set {
      let index = members.firstIndex { $0.key == key }
      switch (index, newValue) {
      case (let index?, let value?): members[index].value = value
      case (let index?, nil): members.remove(at: index)
      case (nil, let value?): members.append((key, value))
      case (nil, nil): break
      }
    }
  }

  public static func == (a: JSONObject, b: JSONObject) -> Bool {
    a.members.count == b.members.count
      && zip(a.members, b.members).allSatisfy { $0.key == $1.key && $0.value == $1.value }
  }
}

extension JSONValue {
  public var object: JSONObject? { if case .object(let value) = self { value } else { nil } }
  public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
  public var string: String? { if case .string(let value) = self { value } else { nil } }
  public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
  /// A number that is finite. `1e999` parses, as it does in JavaScript, to infinity.
  public var finite: Double? {
    if case .number(let value) = self, value.isFinite { value } else { nil }
  }
}

// MARK: - Reading

extension JSONValue {
  /// Nil for anything `JSON.parse` would throw on.
  public init?(parsing text: String) {
    var parser = Parser(bytes: Array(text.utf8))
    parser.skipWhitespace()
    guard let value = parser.value(depth: 0) else { return nil }
    parser.skipWhitespace()
    guard parser.at == parser.bytes.count else { return nil }
    self = value
  }
}

private struct Parser {
  let bytes: [UInt8]
  var at = 0

  var peek: UInt8? { at < bytes.count ? bytes[at] : nil }

  mutating func skipWhitespace() {
    while let byte = peek, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { at += 1 }
  }

  mutating func take(_ literal: String) -> Bool {
    let wanted = Array(literal.utf8)
    guard at + wanted.count <= bytes.count, Array(bytes[at..<at + wanted.count]) == wanted else {
      return false
    }
    at += wanted.count
    return true
  }

  mutating func value(depth: Int) -> JSONValue? {
    // Deep enough for any document and shallow enough that a hostile one cannot overflow the stack.
    guard depth < 256, let byte = peek else { return nil }
    switch byte {
    case UInt8(ascii: "{"): return object(depth: depth)
    case UInt8(ascii: "["): return array(depth: depth)
    case UInt8(ascii: "\""): return string().map(JSONValue.string)
    case UInt8(ascii: "t"): return take("true") ? .bool(true) : nil
    case UInt8(ascii: "f"): return take("false") ? .bool(false) : nil
    case UInt8(ascii: "n"): return take("null") ? .null : nil
    default: return number()
    }
  }

  mutating func object(depth: Int) -> JSONValue? {
    at += 1
    var object = JSONObject()
    skipWhitespace()
    if peek == UInt8(ascii: "}") {
      at += 1
      return .object(object)
    }
    while true {
      skipWhitespace()
      guard peek == UInt8(ascii: "\""), let key = string() else { return nil }
      skipWhitespace()
      guard peek == UInt8(ascii: ":") else { return nil }
      at += 1
      skipWhitespace()
      guard let member = value(depth: depth + 1) else { return nil }
      object[key] = member
      skipWhitespace()
      if peek == UInt8(ascii: ",") {
        at += 1
      } else if peek == UInt8(ascii: "}") {
        at += 1
        return .object(object)
      } else {
        return nil
      }
    }
  }

  mutating func array(depth: Int) -> JSONValue? {
    at += 1
    var elements: [JSONValue] = []
    skipWhitespace()
    if peek == UInt8(ascii: "]") {
      at += 1
      return .array(elements)
    }
    while true {
      skipWhitespace()
      guard let element = value(depth: depth + 1) else { return nil }
      elements.append(element)
      skipWhitespace()
      if peek == UInt8(ascii: ",") {
        at += 1
      } else if peek == UInt8(ascii: "]") {
        at += 1
        return .array(elements)
      } else {
        return nil
      }
    }
  }

  /// The grammar is checked by hand and the conversion left to `Double`, which rounds correctly —
  /// the same answer JavaScript gets for the same digits.
  mutating func number() -> JSONValue? {
    let start = at
    func isDigit(_ byte: UInt8?) -> Bool { byte.map { $0 >= 0x30 && $0 <= 0x39 } ?? false }
    if peek == UInt8(ascii: "-") { at += 1 }
    guard isDigit(peek) else { return nil }
    if peek == UInt8(ascii: "0") {
      at += 1
    } else {
      while isDigit(peek) { at += 1 }
    }
    if peek == UInt8(ascii: ".") {
      at += 1
      guard isDigit(peek) else { return nil }
      while isDigit(peek) { at += 1 }
    }
    if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
      at += 1
      if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { at += 1 }
      guard isDigit(peek) else { return nil }
      while isDigit(peek) { at += 1 }
    }
    return Double(String(decoding: bytes[start..<at], as: UTF8.self)).map(JSONValue.number)
  }

  mutating func string() -> String? {
    at += 1
    var units: [UInt16] = []
    var plain = at
    func flush(_ parser: Parser, upTo end: Int) {
      units.append(contentsOf: String(decoding: parser.bytes[plain..<end], as: UTF8.self).utf16)
    }
    while let byte = peek {
      switch byte {
      case UInt8(ascii: "\""):
        flush(self, upTo: at)
        at += 1
        // A lone surrogate cannot live in a Swift string; it becomes U+FFFD here.
        return String(decoding: units, as: UTF16.self)
      case UInt8(ascii: "\\"):
        flush(self, upTo: at)
        at += 1
        guard let escape = peek else { return nil }
        at += 1
        switch escape {
        case UInt8(ascii: "\""): units.append(0x22)
        case UInt8(ascii: "\\"): units.append(0x5C)
        case UInt8(ascii: "/"): units.append(0x2F)
        case UInt8(ascii: "b"): units.append(0x08)
        case UInt8(ascii: "f"): units.append(0x0C)
        case UInt8(ascii: "n"): units.append(0x0A)
        case UInt8(ascii: "r"): units.append(0x0D)
        case UInt8(ascii: "t"): units.append(0x09)
        case UInt8(ascii: "u"):
          guard at + 4 <= bytes.count,
            let unit = UInt16(String(decoding: bytes[at..<at + 4], as: UTF8.self), radix: 16)
          else { return nil }
          units.append(unit)
          at += 4
        default: return nil
        }
        plain = at
      case 0..<0x20:
        return nil
      default:
        at += 1
      }
    }
    return nil
  }
}

// MARK: - Writing

extension JSONValue {
  /// As `JSON.stringify` writes it: no whitespace, members in order.
  public var text: String {
    var out = ""
    write(to: &out)
    return out
  }

  private func write(to out: inout String) {
    switch self {
    case .null: out += "null"
    case .bool(let value): out += value ? "true" : "false"
    case .number(let value): out += JSONValue.format(value)
    case .string(let value): JSONValue.quote(value, to: &out)
    case .array(let elements):
      out += "["
      for (index, element) in elements.enumerated() {
        if index > 0 { out += "," }
        element.write(to: &out)
      }
      out += "]"
    case .object(let object):
      out += "{"
      for (index, member) in object.members.enumerated() {
        if index > 0 { out += "," }
        JSONValue.quote(member.key, to: &out)
        out += ":"
        member.value.write(to: &out)
      }
      out += "}"
    }
  }

  static func quote(_ string: String, to out: inout String) {
    out += "\""
    for scalar in string.unicodeScalars {
      switch scalar.value {
      case 0x22: out += "\\\""
      case 0x5C: out += "\\\\"
      case 0x08: out += "\\b"
      case 0x0C: out += "\\f"
      case 0x0A: out += "\\n"
      case 0x0D: out += "\\r"
      case 0x09: out += "\\t"
      case 0..<0x20:
        let hex = String(scalar.value, radix: 16)
        out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
      default: out.unicodeScalars.append(scalar)
      }
    }
    out += "\""
  }

  /// A number as ECMAScript's `Number::toString` lays it out.
  ///
  /// Swift and JavaScript agree on the hard part — both print the shortest digits that read back
  /// as the same double — and differ only in where the point and the exponent go. So the digits
  /// come from `description` and are laid out again by JavaScript's rules.
  static func format(_ value: Double) -> String {
    guard value.isFinite else { return "null" }
    if value == 0 { return "0" }
    let sign = value < 0 ? "-" : ""

    // "120.0", "0.72", "1e-07", "1.5e+20": mantissa digits, and where the point falls.
    let parts = value.magnitude.description.split(separator: "e")
    let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    var digits = Array((mantissa[0] + (mantissa.count > 1 ? mantissa[1] : "")).utf8)
    var point = mantissa[0].count + (parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
    while digits.count > 1, digits.first == UInt8(ascii: "0") {
      digits.removeFirst()
      point -= 1
    }
    while digits.count > 1, digits.last == UInt8(ascii: "0") { digits.removeLast() }

    let text = String(decoding: digits, as: UTF8.self)
    let count = digits.count
    if count <= point, point <= 21 {
      return sign + text + String(repeating: "0", count: point - count)
    }
    if 0 < point, point <= 21 {
      return sign + text.prefix(point) + "." + text.dropFirst(point)
    }
    if -6 < point, point <= 0 {
      return sign + "0." + String(repeating: "0", count: -point) + text
    }
    let exponent = point - 1
    let head = count == 1 ? text : text.prefix(1) + "." + text.dropFirst()
    return sign + head + "e" + (exponent < 0 ? "-" : "+") + String(exponent.magnitude)
  }
}
