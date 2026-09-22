#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxEngine
  import SwiftUI

  /// Driftbox's look, which is the web app's: a night-indigo ground, panels of smoked glass over
  /// the visuals, monospaced labels, and one colour per machine — pink for the 808, teal for the
  /// 909 and for the playhead, amber for the 303s. The same
  /// values as the web's stylesheet, so the two read as one instrument.
  enum Theme {
    static let ground = Color(red: 7 / 255, green: 4 / 255, blue: 15 / 255)
    static let panel = Color(red: 14 / 255, green: 10 / 255, blue: 30 / 255).opacity(0.58)
    static let edge = Color.white.opacity(0.09)
    static let ink = Color(red: 232 / 255, green: 228 / 255, blue: 1)
    static let dim = Color(red: 157 / 255, green: 149 / 255, blue: 200 / 255)
    static let eight = Color(red: 1, green: 122 / 255, blue: 217 / 255)
    static let nine = Color(red: 95 / 255, green: 240 / 255, blue: 208 / 255)
    static let three = Color(red: 1, green: 176 / 255, blue: 46 / 255)
    static let violet = Color(red: 169 / 255, green: 149 / 255, blue: 1)

    /// The playhead, and anything else that is "now".
    static let live = nine

    /// A machine's colour: what its steps light in and what its panel is headed with.
    static func color(_ machine: Machine) -> Color { machine == .tr808 ? eight : nine }

    /// A lit step, top to bottom, as the web draws one.
    static func stepFill(_ machine: Machine) -> LinearGradient {
      machine == .tr808
        ? gradient(
          Color(red: 1, green: 156 / 255, blue: 228 / 255),
          Color(red: 217 / 255, green: 79 / 255, blue: 176 / 255))
        : gradient(
          Color(red: 159 / 255, green: 1, blue: 240 / 255),
          Color(red: 39 / 255, green: 185 / 255, blue: 159 / 255))
    }

    static let accentFill = gradient(Color(red: 1, green: 243 / 255, blue: 168 / 255), three)
    static let accentGlow = Color(red: 1, green: 190 / 255, blue: 70 / 255)
    static let bassFill = gradient(
      Color(red: 1, green: 214 / 255, blue: 140 / 255),
      Color(red: 230 / 255, green: 140 / 255, blue: 20 / 255))

    static func gradient(_ top: Color, _ bottom: Color) -> LinearGradient {
      LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    /// The typeface everything is set in.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
      .system(size: size, weight: weight, design: .monospaced)
    }
  }

  /// A panel: smoked glass with a hairline edge, over whatever is behind it.
  struct PanelBackground: ViewModifier {
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
      content
        .background {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.edge))
        }
    }
  }

  extension View {
    func panel(radius: CGFloat = 12) -> some View { modifier(PanelBackground(radius: radius)) }
  }

  /// A small uppercase caption, the way the web labels a field.
  struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
      Text(text.uppercased()).font(Theme.mono(9, .medium)).tracking(0.8).foregroundStyle(Theme.dim)
    }
  }

  /// The web's button: a dark rounded chip with a hairline edge that brightens under the
  /// pointer and gives a little under a press. `on` lights it in `tint`, edge, text and glow.
  struct ChipStyle: ButtonStyle {
    var on = false
    var tint = Theme.nine
    var size: CGFloat = 11

    func makeBody(configuration: Configuration) -> some View {
      Chip(configuration: configuration, on: on, tint: tint, size: size)
    }

    struct Chip: View {
      let configuration: Configuration
      let on: Bool
      let tint: Color
      let size: CGFloat
      @State private var hovering = false
      @Environment(\.isEnabled) private var enabled

      var body: some View {
        configuration.label
          .font(Theme.mono(size))
          .foregroundStyle(on ? tint : Theme.ink.opacity(enabled ? 0.92 : 0.35))
          .padding(.horizontal, 9)
          .frame(minHeight: 24)
          .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .fill(on ? tint.opacity(0.12) : Color.white.opacity(configuration.isPressed ? 0.1 : 0.045))
              .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                  .strokeBorder(
                    on ? tint.opacity(0.9) : Color.white.opacity(hovering && enabled ? 0.3 : 0.1))
              )
              .shadow(color: on ? tint.opacity(0.35) : .clear, radius: 8)
          }
          .scaleEffect(configuration.isPressed ? 0.96 : 1)
          .animation(.spring(response: 0.18, dampingFraction: 0.6), value: configuration.isPressed)
          .animation(.easeOut(duration: 0.12), value: hovering)
          .onHover { hovering = $0 }
          .contentShape(Rectangle())
      }
    }
  }

  extension ButtonStyle where Self == ChipStyle {
    static var chip: ChipStyle { ChipStyle() }
    static func chip(on: Bool, tint: Color = Theme.nine, size: CGFloat = 11) -> ChipStyle {
      ChipStyle(on: on, tint: tint, size: size)
    }
  }
#endif
