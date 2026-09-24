import DriftboxSession
import DriftboxShell

/// The keyboard as an instrument, as the Mac and the web have it. The number row strikes the drum
/// voices the song uses, in the grid's order; the home row plays 303 A, the black keys on the row
/// above, with `z` and `x` shifting the octave down and up.
///
/// Only a key pressed with nothing held: a shortcut is the menus', and a key held down to repeat
/// would be a drum roll nobody asked for.
@MainActor
public struct KeyboardInstrument {
  public static let bassKeys: [Character: Int] = [
    "a": 0, "w": 1, "s": 2, "d": 3, "r": 4, "f": 5, "t": 6, "g": 7, "h": 8, "u": 9, "j": 10, "i": 11,
    "k": 12,
  ]
  public static let drumKeys: [Character] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="]

  /// Octaves from the middle one, -1...1.
  public private(set) var octave = 0

  public init() {}

  /// Play `event` on `session`, if it is one of the instrument's keys. False for anything else.
  public mutating func play(_ event: KeyEvent, on session: Session) -> Bool {
    guard event.isDown, !event.isRepeat, event.modifiers.isEmpty, case .character(let character) = event.key
    else { return false }
    if let semitone = Self.bassKeys[character] {
      session.playNote(semitone: semitone + octave * 12, accent: false)
      return true
    }
    if let index = Self.drumKeys.firstIndex(of: character) {
      session.strike(index: index, accent: false)
      return true
    }
    switch character {
    case "z":
      octave = max(-1, octave - 1)
      return true
    case "x":
      octave = min(1, octave + 1)
      return true
    default:
      return false
    }
  }
}
