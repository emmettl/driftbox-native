#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxEngine
  import DriftboxSeq
  import DriftboxSession
  import SwiftUI

  /// The keyboard as an instrument. The number row strikes the drum voices the song uses, in grid
  /// order; the home row plays the 303 whose knobs are showing, or 303 A, the way the web app's
  /// keys do, accented with Shift, with `z` and `x` shifting the octave. With step entry on, the
  /// notes are written into the stopped pattern too, Delete writes a rest and Return a tie.
  /// Handled at the window, so it works wherever focus is.
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
        let accent = press.modifiers == .shift
        guard press.modifiers.isEmpty || accent, let character = press.characters.lowercased().first else {
          return .ignored
        }
        if let semitone = Self.bassKeys[character] {
          if player.entryStep != nil {
            player.enterNote(semitone: semitone + octave * 12, accent: accent)
          } else {
            player.playNote(semitone: semitone + octave * 12, accent: accent)
          }
          return .handled
        }
        guard !accent else { return .ignored }
        if player.entryStep != nil {
          if press.key == .delete {
            player.enterRest()
            return .handled
          }
          if press.key == .return {
            player.enterTie()
            return .handled
          }
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
