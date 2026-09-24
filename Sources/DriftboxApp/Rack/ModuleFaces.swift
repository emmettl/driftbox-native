#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxDocument
  import DriftboxRack
  import Foundation
  import SwiftUI

  /// What the rack's panels say that the sound does not need — each module's shelf in the
  /// picker, its line of copy, its picture and its selectors' words — read from `modules.json`,
  /// which the reference's own definitions are exported into. In the picker's order.
  struct ModuleFace: Decodable, Equatable {
    struct Logo: Decodable, Equatable {
      var paths: [String]
    }

    var type: String
    var group: String?
    var blurb: String?
    var logo: Logo?
    var labels: [String: [String]]

    static let all: [ModuleFace] = {
      guard let url = Bundle.module.url(forResource: "modules", withExtension: "json"),
        let data = try? Data(contentsOf: url)
      else { return native }
      return ((try? JSONDecoder().decode([ModuleFace].self, from: data)) ?? []) + native
    }()

    /// The modules the reference has none of, so its export has no card for.
    static let native = [
      ModuleFace(
        type: "plugin", group: "Effects",
        blurb:
          "An Audio Unit effect from this Mac, in stereo, with its own controls a click away. The patch keeps "
          + "which one and how it is set, even where it is missing.",
        logo: Logo(paths: [
          "M14 9v8M24 9v8", "M9 17h20v6a10 10 0 0 1-20 0z", "M19 33v5",
          "M36 23c3-8 6-8 9 0s6 8 9 0",
        ]),
        labels: [:]),
      ModuleFace(
        type: "plugin-instrument", group: "Sources",
        blurb:
          "An Audio Unit instrument from this Mac, played by the rack's notes, every voice of them, with "
          + "mod, bend and sustain. Comes wired to the keys.",
        logo: Logo(paths: [
          "M8 10h48v22H8z", "M16 10v14M24 10v14M40 10v14M48 10v14", "M32 10v22",
        ]),
        labels: [:]),
    ]

    static let byType: [String: ModuleFace] = Dictionary(
      all.map { ($0.type, $0) }, uniquingKeysWith: { a, _ in a })

    /// The picker's shelves, in the order their first module appears, holding only the modules
    /// this build can make.
    static var shelves: [(name: String, types: [String])] {
      var order: [String] = []
      var shelves: [String: [String]] = [:]
      for face in all where RackModules.registry[face.type] != nil {
        let group = face.group ?? "Other"
        if shelves[group] == nil { order.append(group) }
        shelves[group, default: []].append(face.type)
      }
      return order.map { ($0, shelves[$0]!) }
    }

    /// The shelf's colour, as the picker's cards have it.
    static func accent(_ group: String?) -> Color {
      switch group {
      case "Sources", "Sequencing": Theme.three
      case "Filters", "Shaping", "Mixing": Theme.eight
      default: Theme.nine
      }
    }
  }

  /// A factory patch, as the picker lists it.
  struct PatchEntry: Decodable, Equatable, Identifiable {
    var id: String
    var name: String
    var blurb: String
    var category: String?
    var accent: String
    var play: String?
    var tip: String?

    static let all: [PatchEntry] = {
      guard let url = Bundle.module.url(forResource: "patches", withExtension: "json"),
        let data = try? Data(contentsOf: url)
      else { return [] }
      return (try? JSONDecoder().decode([PatchEntry].self, from: data)) ?? []
    }()

    /// The patch itself, as the reference saved it.
    func load() -> Patch? {
      guard
        let url = Bundle.module.url(forResource: id, withExtension: "patch.json", subdirectory: "Patches"),
        let text = try? String(contentsOf: url, encoding: .utf8)
      else { return nil }
      return PatchCodec.decode(text)
    }

    var color: Color {
      switch accent {
      case "pink": Theme.eight
      case "amber": Theme.three
      case "violet": Theme.violet
      default: Theme.nine
      }
    }
  }

  /// An SVG path's `d`, as a SwiftUI path: the commands the modules' logos use, which are moves,
  /// lines, horizontals and verticals, cubics with their shorthand, arcs and closes, each in
  /// either case.
  enum SVGPath {
    static func parse(_ d: String) -> Path {
      var path = Path()
      var tokens = Tokens(d)
      var current = CGPoint.zero
      var start = CGPoint.zero
      var lastControl: CGPoint?
      var command: Character = "M"
      while let next = tokens.command() ?? (tokens.hasNumber ? command : nil) {
        // A move's extra pairs are lines.
        command = next
        let relative = command.isLowercase
        func point() -> CGPoint? {
          guard let x = tokens.number(), let y = tokens.number() else { return nil }
          return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }
        var control: CGPoint?
        switch command.uppercased().first! {
        case "M":
          guard let p = point() else { return path }
          path.move(to: p)
          current = p
          start = p
          command = relative ? "l" : "L"
        case "L":
          guard let p = point() else { return path }
          path.addLine(to: p)
          current = p
        case "H":
          guard let x = tokens.number() else { return path }
          current.x = relative ? current.x + x : x
          path.addLine(to: current)
        case "V":
          guard let y = tokens.number() else { return path }
          current.y = relative ? current.y + y : y
          path.addLine(to: current)
        case "C":
          guard let c1 = point(), let c2 = point(), let p = point() else { return path }
          path.addCurve(to: p, control1: c1, control2: c2)
          control = c2
          current = p
        case "S":
          let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
          guard let c2 = point(), let p = point() else { return path }
          path.addCurve(to: p, control1: c1, control2: c2)
          control = c2
          current = p
        case "A":
          guard let rx = tokens.number(), let ry = tokens.number(), let rotation = tokens.number(),
            let large = tokens.flag(), let sweep = tokens.flag(), let p = point()
          else { return path }
          arc(&path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
          current = p
        case "Z":
          path.closeSubpath()
          current = start
        default:
          return path
        }
        lastControl = control
      }
      return path
    }

    /// An endpoint arc, converted to its centre form and drawn as cubic pieces.
    private static func arc(
      _ path: inout Path, from: CGPoint, to: CGPoint, rx: Double, ry: Double, rotation: Double, large: Bool,
      sweep: Bool
    ) {
      var rx = abs(rx)
      var ry = abs(ry)
      if rx == 0 || ry == 0 || from == to {
        path.addLine(to: to)
        return
      }
      let phi = rotation * .pi / 180
      let cosPhi = cos(phi)
      let sinPhi = sin(phi)
      let dx = (from.x - to.x) / 2
      let dy = (from.y - to.y) / 2
      let x1 = cosPhi * dx + sinPhi * dy
      let y1 = -sinPhi * dx + cosPhi * dy
      let scale = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
      if scale > 1 {
        rx *= scale.squareRoot()
        ry *= scale.squareRoot()
      }
      let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
      let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
      var factor = (max(0, numerator / denominator)).squareRoot()
      if large == sweep { factor = -factor }
      let cx1 = factor * rx * y1 / ry
      let cy1 = -factor * ry * x1 / rx
      let cx = cosPhi * cx1 - sinPhi * cy1 + (from.x + to.x) / 2
      let cy = sinPhi * cx1 + cosPhi * cy1 + (from.y + to.y) / 2
      func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
        let sign: Double = ux * vy - uy * vx < 0 ? -1 : 1
        let dot = (ux * vx + uy * vy) / ((ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot())
        return sign * acos(max(-1, min(1, dot)))
      }
      let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
      var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
      if !sweep, delta > 0 { delta -= 2 * .pi }
      if sweep, delta < 0 { delta += 2 * .pi }
      let pieces = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
      let step = delta / Double(pieces)
      let k = 4.0 / 3.0 * tan(step / 4)
      func at(_ t: Double) -> (CGPoint, CGPoint) {
        let x = rx * cos(t)
        let y = ry * sin(t)
        let point = CGPoint(x: cosPhi * x - sinPhi * y + cx, y: sinPhi * x + cosPhi * y + cy)
        let tx = -rx * sin(t)
        let ty = ry * cos(t)
        return (point, CGPoint(x: cosPhi * tx - sinPhi * ty, y: sinPhi * tx + cosPhi * ty))
      }
      var t = theta
      for _ in 0..<pieces {
        let (p0, d0) = at(t)
        let (p1, d1) = at(t + step)
        path.addCurve(
          to: p1, control1: CGPoint(x: p0.x + k * d0.x, y: p0.y + k * d0.y),
          control2: CGPoint(x: p1.x - k * d1.x, y: p1.y - k * d1.y))
        t += step
      }
    }

    /// Numbers and commands out of a path string, where "1-2" is two numbers and ".5.5" is too.
    private struct Tokens {
      let characters: [Character]
      var index = 0

      init(_ text: String) { characters = Array(text) }

      mutating func skip() {
        while index < characters.count,
          characters[index] == " " || characters[index] == ","
            || characters[index].isNewline
        {
          index += 1
        }
      }

      var hasNumber: Bool {
        mutating get {
          skip()
          guard index < characters.count else { return false }
          let c = characters[index]
          return c.isNumber || c == "-" || c == "." || c == "+"
        }
      }

      mutating func command() -> Character? {
        skip()
        guard index < characters.count, characters[index].isLetter else { return nil }
        defer { index += 1 }
        return characters[index]
      }

      mutating func number() -> Double? {
        skip()
        var text = ""
        var seenDot = false
        var seenExponent = false
        while index < characters.count {
          let c = characters[index]
          if c == "-" || c == "+" {
            if !text.isEmpty && !(text.last == "e" || text.last == "E") { break }
          } else if c == "." {
            if seenDot || seenExponent { break }
            seenDot = true
          } else if c == "e" || c == "E" {
            if seenExponent || text.isEmpty { break }
            seenExponent = true
          } else if !c.isNumber {
            break
          }
          text.append(c)
          index += 1
        }
        return Double(text)
      }

      /// An arc's flag: one digit, which may run straight into the next number.
      mutating func flag() -> Bool? {
        skip()
        guard index < characters.count, characters[index] == "0" || characters[index] == "1" else {
          return nil
        }
        defer { index += 1 }
        return characters[index] == "1"
      }
    }
  }
#endif
