#if os(Android)
  import DriftboxShell

  /// A menu as lines of text, for Java to show as Android's own: the first says where it was pressed,
  /// in points, and its title; then one line an item, its depth first, so a submenu's items follow
  /// it one deeper. Tabs between the fields:
  ///
  ///     x  y  title
  ///     depth  c  id  title  enabled  checked      a command, 1 or 0 for each
  ///     depth  s  -   title                        a submenu, its items next
  ///     depth  -                                   a separator
  ///
  /// Text rather than objects, so that a menu reaches Java as what a frame returns and Swift never
  /// calls into Java to show one.
  enum MenuLines {
    static func write(
      _ menu: Menu, at point: SIMD2<Float>, isEnabled: (String) -> Bool, isChecked: (String) -> Bool
    ) -> String {
      var lines = ["\(point.x)\t\(point.y)\t\(clean(menu.title))"]
      func walk(_ items: [MenuItem], _ depth: Int) {
        for item in items {
          switch item {
          case .command(let command):
            lines.append(
              "\(depth)\tc\t\(command.id)\t\(clean(command.title))\t\(isEnabled(command.id) ? 1 : 0)\t"
                + "\(isChecked(command.id) ? 1 : 0)")
          case .submenu(let submenu):
            lines.append("\(depth)\ts\t-\t\(clean(submenu.title))")
            walk(submenu.items, depth + 1)
          case .separator:
            lines.append("\(depth)\t-")
          }
        }
      }
      walk(menu.items, 0)
      return lines.joined(separator: "\n")
    }

    /// A title with nothing in it that would end a field or a line early.
    private static func clean(_ text: String) -> String {
      String(text.map { $0 == "\t" || $0 == "\n" ? " " : $0 })
    }
  }
#endif
