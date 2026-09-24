#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxEngine
  import DriftboxSeq
  import DriftboxSession
  import SwiftUI

  /// The keyboard as an instrument. The number row strikes the drum voices the song uses, in grid
  /// order; the home row plays the 303 A the way the web app's keys do, with `z` and `x` shifting
  /// the octave. Handled at the window, so it works wherever focus is.
  struct Keys: ViewModifier {
    let player: Session
    @State private var octave = 0

    static let bassKeys: [Character: Int] = [
      "a": 0, "w": 1, "s": 2, "d": 3, "r": 4, "f": 5, "t": 6, "g": 7, "h": 8, "u": 9, "j": 10, "i": 11,
      "k": 12,
    ]
    static let drumKeys: [Character] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="]

    func body(content: Content) -> some View {
      content.onKeyPress(phases: .down) { press in
        guard press.modifiers.isEmpty, let character = press.characters.first else { return .ignored }
        if let semitone = Self.bassKeys[character] {
          player.playNote(semitone: semitone + octave * 12, accent: false)
          return .handled
        }
        if let index = Self.drumKeys.firstIndex(of: character) {
          player.strike(index: index, accent: false)
          return .handled
        }
        switch character {
        case "z":
          octave = max(-1, octave - 1)
          return .handled
        case "x":
          octave = min(1, octave + 1)
          return .handled
        default:
          return .ignored
        }
      }
    }
  }
#endif
