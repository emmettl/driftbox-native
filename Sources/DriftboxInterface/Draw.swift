import DriftboxCanvas
import Foundation

// C's maths, which Foundation brings with it on Apple's platforms and not on Android.
#if canImport(Android)
  import Android
#endif

/// What every drawn interface draws its parts with: a panel of smoked glass, a chip, a knob. The
/// groovebox's controls and the rack both draw with these, so the two look like one instrument.
enum Draw {
  /// A panel: smoked glass with a hairline edge, over whatever is behind it.
  static func panel(_ rect: Rect, radius: Float = 12, on canvas: Canvas) {
    canvas.fill = Theme.panel
    canvas.fillRoundedRect(rect.x, rect.y, rect.width, rect.height, radius: radius)
    canvas.stroke = Theme.edge
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(rect.x, rect.y, rect.width, rect.height, radius: radius)
  }

  /// A button as the web draws one: a dark rounded chip with a hairline edge that brightens under
  /// the pointer, lit in `tint` when it is on, and giving a little while it is held.
  static func chip(
    _ frame: Rect, label: String, isOn: Bool, hovered: Bool, down: Bool, tint: Colour = Theme.nine,
    size: Float = 11, on canvas: Canvas
  ) {
    canvas.fill = isOn ? tint.faded(0.12) : Theme.white(down ? 0.1 : 0.045)
    canvas.fillRoundedRect(frame.x, frame.y, frame.width, frame.height, radius: 7)
    canvas.stroke = isOn ? tint.faded(0.9) : Theme.white(hovered ? 0.3 : 0.1)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(frame.x, frame.y, frame.width, frame.height, radius: 7)
    canvas.font = Theme.mono(size)
    canvas.fill = isOn ? tint : Theme.ink.faded(0.92)
    canvas.align = .center
    canvas.fillText(label, frame.x + frame.width / 2, frame.y + frame.height / 2 + size * 0.36)
  }

  /// A knob, as the Mac draws one: a dark cap lit from above, its travel round it with `value`
  /// (0...1) lit in `tint`, a pointer, and its name and value underneath.
  static func knob(
    _ dial: Rect, value: Double, label: String, text: String, tint: Colour, active: Bool, hovered: Bool,
    opacity: Float = 1, on canvas: Canvas
  ) {
    // Faint all through when asleep: every colour is taken down together.
    func a(_ colour: Colour) -> Colour { colour.faded(opacity) }
    let d = dial.width
    let centre = SIMD2(dial.x + d / 2, dial.y + d / 2)
    // The cap.
    let cap = dial.outset(-d * 0.2)
    canvas.fill = a(Theme.white(0.12))
    canvas.fillRoundedRect(
      cap.x, cap.y, cap.width, cap.height, radius: cap.width / 2, foot: a(Theme.white(0.02)))
    canvas.stroke = a(Theme.white(0.1))
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(cap.x, cap.y, cap.width, cap.height, radius: cap.width / 2)
    // The travel, and the value along it, with a glow under.
    let sweep = Float.pi * 1.5
    let start = -sweep / 2
    let end = start + sweep * Float(max(0.0001, min(1, value)))
    let radius = d / 2 - 2
    canvas.lineWidth = 3
    canvas.stroke = a(Theme.white(0.12))
    canvas.strokeArc(centre.x, centre.y, radius: radius, from: start, to: start + sweep)
    canvas.lineWidth = 7
    canvas.stroke = a(tint.faded(active ? 0.35 : hovered ? 0.22 : 0.12))
    canvas.strokeArc(centre.x, centre.y, radius: radius, from: start, to: end)
    canvas.lineWidth = 3
    canvas.stroke = a(tint)
    canvas.strokeArc(centre.x, centre.y, radius: radius, from: start, to: end)
    // The pointer.
    let direction = SIMD2(sin(end), -cos(end))
    canvas.stroke = a(Theme.ink)
    canvas.lineWidth = 2
    canvas.strokeLines([(centre + direction * (d * 0.08), centre + direction * (d * 0.3))])
    // Its name and where it is.
    canvas.align = .center
    canvas.font = Theme.mono(8.5, weight: 500)
    canvas.fill = a(Theme.dim)
    canvas.fillText(label.uppercased(), centre.x, dial.maxY + 12)
    canvas.font = Theme.mono(9.5)
    canvas.fill = a(active ? Theme.ink : Theme.ink.faded(0.55))
    canvas.fillText(text, centre.x, dial.maxY + 25)
  }
}
