import DriftboxEngine
import DriftboxHost
import DriftboxSeq

/// A performance, as it was played: where the engine stood when it began, and everything done to
/// the engine after, each at the frame of the engine's clock it took effect on. Enough to play the
/// performance again on an engine of its own — as a movie is made — and hear what was heard.
///
/// What is kept is what reached the engine, not the gestures that made it: an edit is the song it
/// left, a key the voice it struck, the pad where it was touched. The engine is a function of its
/// commands and when they arrive, so that is the performance.
public struct Take {
  public enum Event {
    /// A command as the session sent it. Never `.load`, whose song is a pointer only the engine
    /// that compiled it can read: a song arrives as `.song`.
    case command(Command)
    /// A song loaded: an edit, or a different song opened.
    case song(Song)
    /// The scene the visuals switched to, or the song's own for nil: not the engine's, but part of
    /// what was seen.
    case scene(String?)
  }

  /// The engine's rate, which its frames count in.
  public var sampleRate: Double
  /// Where the engine's clock stood when the take began and ended.
  public var start: Int
  public var end: Int
  /// The engine as it was at the start: the song, where in it, and how it was set to play.
  public var song: Song
  public var songFrame: Int
  public var playing: Bool
  public var loop: (start: Int, bars: Int)?
  public var metronome: Bool
  /// The scene showing at the start, or the song's own for nil.
  public var scene: String?
  /// Everything after, in the order it happened, at the engine frame it took effect on.
  public var events: [(frame: Int, event: Event)]

  public init(
    sampleRate: Double, start: Int, end: Int, song: Song, songFrame: Int = 0, playing: Bool,
    loop: (start: Int, bars: Int)? = nil, metronome: Bool = false, scene: String? = nil,
    events: [(frame: Int, event: Event)] = []
  ) {
    self.sampleRate = sampleRate
    self.start = start
    self.end = end
    self.song = song
    self.songFrame = songFrame
    self.playing = playing
    self.loop = loop
    self.metronome = metronome
    self.scene = scene
    self.events = events
  }

  /// How long it lasted, in seconds.
  public var seconds: Double { Double(max(0, end - start)) / sampleRate }

  /// A song played through from the top, once, and left to ring for `tail` seconds: a take nobody
  /// played, which is what exporting a song is.
  public static func song(_ song: Song, sampleRate: Double, tail: Double) -> Take {
    let length = Int(SongRenderer.seconds(of: song) * sampleRate)
    return Take(
      sampleRate: sampleRate, start: 0, end: length + Int(tail * sampleRate), song: song, playing: true,
      scene: nil, events: [(length, .command(.stop))])
  }
}
