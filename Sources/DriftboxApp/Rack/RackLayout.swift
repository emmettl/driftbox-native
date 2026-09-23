#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxRack
  import Foundation

  /// Where every module and every jack sits, in one design space shared by the front, the back
  /// and the cables: a port of the reference's `layout.ts` and of the sizes in its faceplate
  /// table, held to them exactly by `RackPanelTests`. Arithmetic rather than measurement, so a
  /// cable never waits on a view having been laid out.
  enum RackLayout {
    /// One half-width column; a full-width module is two.
    static let column = 240.0
    /// One row of rack height. Modules are a whole number of rows tall.
    static let row = 60.0
    /// One control's cell on a faceplate. Every control is this size, which is what lets a
    /// module's height be worked out rather than measured.
    static let cellWidth = 58.0
    static let cellHeight = 62.0
    /// The title strip, and the padding above and below the controls.
    static let title = 28.0
    static let pad = 18.0
    /// Vertical pitch between jacks on the back, and how far in from the edge they sit.
    static let jack = 30.0
    static let jackInset = 30.0
    static let width = column * 2
    /// How close a dropped cable has to be to a jack to land on it.
    static let snap = 30.0

    struct Size: Equatable {
      /// Half width (1) or full (2).
      var span: Int
      var rows: Int
    }

    struct Placement: Equatable {
      var id: String
      var type: String
      var span: Int
      /// 0 or 1; always 0 for a full-width module.
      var column: Int
      var row: Int
      var rows: Int
      var x: Double
      var y: Double
      var width: Double
      var height: Double

      var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    struct Layout: Equatable {
      var placements: [Placement]
      var rows: Int
      var width: Double { RackLayout.width }
      var height: Double { Double(rows) * RackLayout.row }
    }

    struct Jack: Equatable {
      enum Kind { case inlet, outlet }
      var module: String
      var port: String
      var name: String
      var kind: Kind
      var aliases: [String]
      var stereo: Bool
      var x: Double
      var y: Double

      var point: CGPoint { CGPoint(x: x, y: y) }
    }

    // MARK: Sizes

    /// The modules with a hand-built front in the reference, with what that front asks for. A
    /// module missing here gets the generic front, sized from its visible params.
    static let handBuilt: [String: (span: Int?, rows: Int?)] = [
      "audio-track": (nil, 4), "arp": (nil, 5), "arranger": (nil, 5), "chord-player": (nil, 5),
      "combi": (nil, 5), "groovebox": (nil, 16), "vco": (1, 2), "ladder": (1, nil), "looper": (nil, 3),
      "midi": (1, 2), "meter": (nil, 3), "multisampler": (nil, 6), "note-echo": (nil, 5), "out": (1, nil),
      "sampler": (nil, 4), "scale-player": (nil, 4), "tracker": (nil, 7), "tuner": (1, 3),
    ]

    /// How many control cells fit across a module of this span.
    static func columns(for span: Int) -> Int { span == 1 ? 3 : 7 }

    /// How big a module is: the larger of what its front and its back need.
    static func size(of type: String, defs: [String: ModuleDef] = RackModules.registry) -> Size {
      let def = defs[type]
      let entry = handBuilt[type]
      let shown = def?.params.filter { !$0.hidden }.count
      let span = entry?.span ?? (entry != nil ? 2 : shown.map { $0 <= columns(for: 1) } == true ? 1 : 2)
      guard let def else { return Size(span: span, rows: entry?.rows ?? 1) }
      let front = entry?.rows ?? genericRows(def, span: span)
      return Size(span: span, rows: max(front, rowsForJacks(def)))
    }

    /// What the generic front needs: a title, then its visible controls in a grid.
    static func genericRows(_ def: ModuleDef, span: Int) -> Int {
      let shown = def.params.filter { !$0.hidden }.count
      if shown == 0 { return 1 }
      let stacked = (Double(shown) / Double(columns(for: span))).rounded(.up)
      return max(1, Int(((title + pad + stacked * cellHeight) / row).rounded(.up)))
    }

    /// Rows a module needs for its jacks alone.
    static func rowsForJacks(_ def: ModuleDef) -> Int {
      let most = max(def.inlets.count, def.outlets.count, 1)
      return max(1, Int(((Double(most - 1) * jack + 40) / row).rounded(.up)))
    }

    /// "3 in · 1 out", with the "in" half dropped when there is none.
    static func portSummary(_ def: ModuleDef) -> String {
      var parts: [String] = []
      if !def.inlets.isEmpty { parts.append("\(def.inlets.count) in") }
      parts.append("\(def.outlets.count) out")
      return parts.joined(separator: " · ")
    }

    // MARK: Stacking

    /// Modules down the rack in patch order. Two neighbouring half-width modules share a row,
    /// which takes the taller of the two; anything else has a row to itself.
    static func layout(_ modules: [PatchModule], size: (String) -> Size = { RackLayout.size(of: $0) })
      -> Layout
    {
      var placements: [Placement] = []
      var row = 0
      var index = 0
      while index < modules.count {
        let module = modules[index]
        let own = size(module.type)
        let next = index + 1 < modules.count ? modules[index + 1] : nil
        let nextSize = next.map { size($0.type) }
        let paired = own.span == 1 && nextSize?.span == 1
        let rows = paired ? max(own.rows, nextSize!.rows) : own.rows
        placements.append(place(module, span: own.span, column: 0, row: row, rows: rows))
        if paired, let next {
          placements.append(place(next, span: 1, column: 1, row: row, rows: rows))
          index += 1
        }
        row += rows
        index += 1
      }
      return Layout(placements: placements, rows: row)
    }

    private static func place(_ module: PatchModule, span: Int, column: Int, row: Int, rows: Int) -> Placement
    {
      Placement(
        id: module.id, type: module.type, span: span, column: column, row: row, rows: rows,
        x: Double(column) * self.column, y: Double(row) * self.row, width: Double(span) * self.column,
        height: Double(rows) * self.row)
    }

    // MARK: Jacks

    /// Every module's jacks on the back: inlets down its left edge and outlets down its right,
    /// each column centred in the module's height, so a chain reads left to right.
    static func jacks(_ placements: [Placement], defs: [String: ModuleDef] = RackModules.registry) -> [Jack] {
      var out: [Jack] = []
      for placement in placements {
        guard let def = defs[placement.type] else { continue }
        func column(_ ports: [DriftboxRack.Port], _ kind: Jack.Kind) {
          let span = Double(ports.count - 1) * jack
          let top = placement.y + placement.height / 2 - span / 2
          for (index, port) in ports.enumerated() {
            out.append(
              Jack(
                module: placement.id, port: port.id, name: port.name, kind: kind,
                aliases: port.aliases.map(\.id), stereo: port.stereo,
                x: kind == .inlet ? placement.x + jackInset : placement.x + placement.width - jackInset,
                y: top + Double(index) * jack))
          }
        }
        column(def.inlets, .inlet)
        column(def.outlets, .outlet)
      }
      return out
    }

    /// A jack by module, port and side — the side is not optional, since a module may have an
    /// inlet and an outlet with the same id — falling back to a port's older ids.
    static func jack(in list: [Jack], module: String, port: String, kind: Jack.Kind) -> Jack? {
      list.first { $0.module == module && $0.port == port && $0.kind == kind }
        ?? list.first { $0.module == module && $0.aliases.contains(port) && $0.kind == kind }
    }

    /// The jack nearest a point within `radius`, optionally of one side only: how a dropped
    /// cable finds what it landed on, and why it snaps.
    static func nearestJack(in list: [Jack], to point: CGPoint, radius: Double, kind: Jack.Kind? = nil)
      -> Jack?
    {
      var best: Jack?
      var closest = radius
      for jack in list where kind == nil || jack.kind == kind {
        let distance = hypot(jack.x - point.x, jack.y - point.y)
        if distance <= closest {
          closest = distance
          best = jack
        }
      }
      return best
    }

    // MARK: Reordering

    /// Where a module dropped at `point` would go, as an index into the module list: a full-width
    /// row is crossed top to bottom at its middle, a row of half-width modules left to right.
    static func dropIndex(_ placements: [Placement], at point: CGPoint) -> Int {
      var index = 0
      while index < placements.count {
        let first = placements[index]
        var row = [first]
        while index + row.count < placements.count, placements[index + row.count].row == first.row {
          row.append(placements[index + row.count])
        }
        let bottom = row.map { $0.y + $0.height }.max()!
        if point.y < first.y { return index }
        if point.y >= bottom {
          index += row.count
          continue
        }
        if row.contains(where: { $0.span == 1 }) {
          return index + row.filter { point.x > $0.x + $0.width / 2 }.count
        }
        return point.y > first.y + first.height / 2 ? index + 1 : index
      }
      return placements.count
    }

    /// `items` with the one at `from` moved to insertion index `to` of the original list; nil
    /// when that is where it already is.
    static func reordered<T>(_ items: [T], from: Int, to: Int) -> [T]? {
      guard from >= 0, from < items.count else { return nil }
      let target = max(0, min(items.count, to))
      if target == from || target == from + 1 { return nil }
      var next = items
      let moved = next.remove(at: from)
      next.insert(moved, at: target > from ? target - 1 : target)
      return next
    }
  }
#endif
