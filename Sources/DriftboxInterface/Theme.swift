import DriftboxCanvas
import DriftboxEngine
import DriftboxText

/// Driftbox's look, which is the web app's and the Mac's: panels of smoked glass over the visuals,
/// monospaced labels, and one colour per machine — pink for the 808, teal for the 909 and for the
/// playhead, amber for the 303s and for an accent.
public enum Theme {
  /// The panels have no blur behind them here, so they are a little darker than the Mac's glass to
  /// read as well over a bright scene.
  public static let panel = Colour(0x0e0a1e, alpha: 0.74)
  public static let edge = Colour(0xffffff, alpha: 0.09)
  public static let ink = Colour(0xe8e4ff)
  public static let dim = Colour(0x9d95c8)
  public static let eight = Colour(0xff7ad9)
  public static let nine = Colour(0x5ff0d0)
  public static let three = Colour(0xffb02e)
  /// A 303 slide.
  public static let violet = Colour(0xa995ff)

  /// The playhead, and anything else that is "now".
  public static let live = nine

  /// A machine's colour: what its lane's light flashes in.
  public static func colour(_ machine: Machine) -> Colour { machine == .tr808 ? eight : nine }

  /// A lit step, top to bottom, as the web draws one.
  public static func stepFill(_ machine: Machine) -> (top: Colour, foot: Colour) {
    machine == .tr808 ? (Colour(0xff9ce4), Colour(0xd94fb0)) : (Colour(0x9ffff0), Colour(0x27b99f))
  }

  public static let accentFill = (top: Colour(0xfff3a8), foot: three)
  public static let accentGlow = Colour(0xffbe46)

  /// A pattern's colour on the song strip, by the order it first comes in the song.
  public static func patternColour(_ index: Int) -> Colour {
    let palette = [eight, nine, three, violet, Colour(0x6aa8ff), Colour(0xff8a6a)]
    return palette[index % palette.count]
  }

  /// White at `alpha`, which is most of what a panel's detail is drawn in.
  public static func white(_ alpha: Float) -> Colour { Colour(0xffffff, alpha: alpha) }

  /// The typeface everything is set in: a monospace each platform has.
  public static func mono(_ size: Float, weight: Int = 400) -> FontRequest {
    FontRequest(
      families: ["Cascadia Mono", "Consolas", "Menlo", "Roboto Mono", "Droid Sans Mono", "monospace"],
      weight: weight, size: size)
  }
}

extension Colour {
  /// The same colour, `amount` as opaque.
  func faded(_ amount: Float) -> Colour {
    var out = self
    out.alpha *= amount
    return out
  }
}
