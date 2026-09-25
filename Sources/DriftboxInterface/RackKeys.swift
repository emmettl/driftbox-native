import DriftboxCanvas
import DriftboxRackSession

/// On a touchscreen, the rack's keys: what the typing keys play on a desktop, as a keyboard across
/// the foot of the screen, the rack above it. A finger each, so a chord is a hand; a finger slid
/// along it plays each key it crosses; and a key struck lower down is struck harder, as a key is
/// on the reference's. Its row says the octave, moves it, and puts the keyboard away.
///
/// Arithmetic, as `BassKeyboard` is: the drawing and the fingers read the same one.
public struct RackKeys {
  public struct Key {
    public var frame: Rect
    /// Semitones above the octave's C.
    public var note: Int
    public var black: Bool
  }

  /// The row of chips over the keys, and the keys under it.
  public static let rowHeight: Float = 40
  public static let keysHeight: Float = 124
  public static let height: Float = rowHeight + keysHeight
  /// A white key: no narrower than a finger, no wider than a hand spans.
  static let narrowestWhite: Float = 46
  static let widestWhite: Float = 64
  static let whites = [0, 2, 4, 5, 7, 9, 11]
  /// The black keys, by the white key each sits after.
  static let blacks: [(note: Int, after: Int)] = [(1, 0), (3, 1), (6, 3), (8, 4), (10, 5)]
  /// Struck at its top, a key is this soft; at its foot, full.
  static let softest = 0.45

  public var frame: Rect
  public var keys: [Key]
  /// The octave down and up, and the keyboard away.
  public var down: Rect
  public var up: Rect
  public var hide: Rect
  /// Where the octave is said, between its chips.
  public var octave: Rect

  /// The keys across `width` points at the foot of a window `size`: as many whole octaves as a
  /// finger's white keys fit, and the C above the last; at least one octave.
  public init(size: SIMD2<Float>, margin: Float) {
    frame = Rect(margin, size.y - margin - Self.height, max(0, size.x - margin * 2), Self.height)
    let inner = Rect(frame.x + 8, frame.y + Self.rowHeight, max(0, frame.width - 16), Self.keysHeight - 8)
    // Whole octaves, and the C above: 7n + 1 white keys; on a phone, where not even the C above fits
    // at a finger's width, the one octave, C to B.
    let fits = inner.width / Self.narrowestWhite
    let octaves = max(1, Int((fits - 1) / 7))
    let count = fits < 8 ? 7 : octaves * 7 + 1
    let white = min(Self.widestWhite, inner.width / Float(count))
    let left = inner.x + (inner.width - white * Float(count)) / 2
    var keys: [Key] = []
    for index in 0..<count {
      let note = (index / 7) * 12 + Self.whites[index % 7]
      keys.append(
        Key(
          frame: Rect(left + Float(index) * white, inner.y, white - 2, inner.height), note: note, black: false
        ))
    }
    // The black keys over them, narrower and shorter, as a keyboard's are.
    for octave in 0..<octaves {
      for black in Self.blacks {
        let after = octave * 7 + black.after
        let x = left + Float(after + 1) * white - white * 0.32
        keys.append(
          Key(
            frame: Rect(x, inner.y, white * 0.64, inner.height * 0.6), note: octave * 12 + black.note,
            black: true))
      }
    }
    self.keys = keys
    let chipY = frame.y + 7
    let chip: Float = Self.rowHeight - 12
    down = Rect(frame.x + 10, chipY, 44, chip)
    octave = Rect(down.maxX + 4, chipY, 52, chip)
    up = Rect(octave.maxX + 4, chipY, 44, chip)
    hide = Rect(frame.maxX - 10 - 60, chipY, 60, chip)
  }

  /// The key under `point`, black keys first, since they sit over the white; and how hard a key
  /// struck there is struck.
  public func key(at point: SIMD2<Float>) -> (key: Key, velocity: Double)? {
    let key =
      keys.last { $0.black && $0.frame.contains(point) }
      ?? keys.first { !$0.black && $0.frame.contains(point) }
    guard let key else { return nil }
    let depth = Double((point.y - key.frame.y) / max(1, key.frame.height))
    return (key, Self.softest + (1 - Self.softest) * min(1, max(0, depth)))
  }
}
