import DriftboxEngine
import DriftboxGPU
import DriftboxHost
import DriftboxSeq
import DriftboxSession
import DriftboxText
import Foundation
import Testing

@testable import DriftboxMovie

#if os(Windows)
  import DriftboxGPUD3D11
#endif

/// A performance and its visuals as a movie: the take played again, then drawn and written, and read
/// back — the tracks, the length, the sound and the picture are what was asked for.
@MainActor
struct MovieTests {
  /// Small and short, so a test is quick: a pass of `steady` is two seconds.
  static let small = MovieFormat(
    width: 320, height: 180, framesPerSecond: 30, sampleRate: 48000, tailSeconds: 0.5)

  /// A kick on each of sixteen steps at 120: two seconds, and a tail.
  static func steady() -> Song {
    var pattern = DriftboxSeq.Pattern(id: "p", name: "Pattern 1", length: 16)
    pattern.tracks["909.bd"] = [StepValue](repeating: .on, count: 16)
    var song = Song(bpm: 120, patterns: [pattern])
    song.chain = [ChainStep(pattern: pattern.id)]
    return song
  }

  /// A writer that keeps count, and a size, of what it was given.
  final class Kept: MovieWriter {
    var frames: [Int] = []
    var bytes: Set<Int> = []
    var samples = 0
    var finished = false
    var cancelled = false
    func appendVideo(_ pixels: [UInt8], frame: Int) throws {
      frames.append(frame)
      bytes.insert(pixels.count)
    }
    func appendAudio(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, start: Int) throws
    {
      #expect(start == samples, "the sound in order, with nothing missed")
      samples += frames
    }
    func finish() throws { finished = true }
    func cancel() { cancelled = true }
  }

  /// A song played again for a movie: a frame's input for every thirtieth of the song and its tail,
  /// and the sound behind them, loud while it plays and quieter as it rings out.
  @Test func theSongIsPlayedAgain() async throws {
    let take = Take.song(Self.steady(), sampleRate: 48000, tail: 0.5)
    let played = try await Movie.perform(take, format: Self.small)
    #expect(played.inputs.count == 75, "two and a half seconds at thirty frames a second")
    #expect(played.left.count == 75 * 1600 && played.right.count == played.left.count)
    func rms(_ range: Range<Int>) -> Double {
      let slice = played.left[range]
      return (slice.reduce(0) { $0 + Double($1) * Double($1) } / Double(slice.count)).squareRoot()
    }
    let playing = rms(24000..<72000)
    let after = rms(105_600..<120_000)
    #expect(playing > 0.02, "\(playing) while it plays")
    #expect(after < playing * 0.5, "\(after) after, against \(playing)")
  }

  /// A take's scene switches are where it switched, unless one scene was asked for throughout.
  @Test func aTakesSwitchesAreKept() async throws {
    var take = Take.song(Self.steady(), sampleRate: 48000, tail: 0)
    take.events.insert((48000, .scene("frost")), at: 0)
    let played = try await Movie.perform(take, format: Self.small)
    #expect(played.scenes.count == 1 && played.scenes[0].from == 31 && played.scenes[0].id == "frost")
    #expect(try await Movie.perform(take, scene: "pulse", format: Self.small).scenes.isEmpty)
  }

  #if os(Windows)
    static func device() throws -> any GPUDevice { try D3D11Device(driver: .software) }

    static func directory() throws -> URL {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "driftbox-movie-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }

    /// The writer alone: a second of red over blue, and a tone, read back as that, the right way up.
    @Test func theWriterWritesWhatItIsGiven() throws {
      let folder = try Self.directory()
      defer { try? FileManager.default.removeItem(at: folder) }
      let url = folder.appendingPathComponent("Plain.mp4")
      let format = Self.small
      let writer = try MediaFoundationMovie(url: url, format: format)
      var picture = [UInt8](repeating: 255, count: format.width * format.height * 4)
      for y in 0..<format.height {
        for x in 0..<format.width {
          let at = (y * format.width + x) * 4
          // BGRA: red above, blue below.
          picture[at] = y < format.height / 2 ? 0 : 255
          picture[at + 1] = 0
          picture[at + 2] = y < format.height / 2 ? 255 : 0
        }
      }
      let chunk = format.samplesPerFrame
      let tone = (0..<chunk * 30).map { Float(sin(Double($0) * 2 * .pi * 440 / 48000) * 0.5) }
      for frame in 0..<30 {
        try writer.appendVideo(picture, frame: frame)
        try tone.withUnsafeBufferPointer { sound in
          try writer.appendAudio(
            left: sound.baseAddress! + frame * chunk, right: sound.baseAddress! + frame * chunk,
            frames: chunk,
            start: frame * chunk)
        }
      }
      try writer.finish()

      let read = try MovieContents.read(url, soundFrom: 0.2, to: 0.8, pictureAt: 0.5)
      #expect(abs(read.seconds - 1) < 0.1, "\(read.seconds) seconds")
      #expect(read.width == 320 && read.height == 180)
      #expect(abs(read.framesPerSecond - 30) < 0.5)
      #expect(read.sampleRate == 48000 && read.channels == 2)
      #expect(
        abs(read.peak - 0.5) < 0.1 && abs(read.rms - 0.354) < 0.05, "peak \(read.peak), rms \(read.rms)")
      func pixel(_ x: Int, _ y: Int) -> (b: Int, g: Int, r: Int) {
        let at = (y * read.width + x) * 4
        return (Int(read.pixels[at]), Int(read.pixels[at + 1]), Int(read.pixels[at + 2]))
      }
      let top = pixel(160, 30)
      let bottom = pixel(160, 150)
      #expect(top.r > 200 && top.b < 60, "red above: \(top)")
      #expect(bottom.b > 200 && bottom.r < 60, "blue below: \(bottom)")
    }

    /// The whole of it, on the software GPU: the song's length and tail, its picture and sound.
    @Test func theMovieHasTheSongsPictureAndSound() async throws {
      let folder = try Self.directory()
      defer { try? FileManager.default.removeItem(at: folder) }
      let url = folder.appendingPathComponent("Steady.mp4")
      try await Movie.write(
        Self.steady(), scene: nil, format: Self.small, device: try Self.device(), typesetter: NoTypesetter(),
        to: try MediaFoundationMovie(url: url, format: Self.small))
      let read = try MovieContents.read(url, soundFrom: 0.5, to: 1.5, pictureAt: 1)
      #expect(abs(read.seconds - 2.5) < 0.1, "\(read.seconds) seconds")
      #expect(read.width == 320 && read.height == 180 && read.channels == 2)
      #expect(read.rms > 0.02, "heard while it plays: \(read.rms)")
      let after = try MovieContents.read(url, soundFrom: 2.2, to: 2.5)
      #expect(after.rms < read.rms * 0.5, "\(after.rms) after, against \(read.rms)")
      var brightest = 0
      var levels = Set<UInt8>()
      for pixel in stride(from: 0, to: read.pixels.count, by: 4) {
        brightest = max(
          brightest, Int(read.pixels[pixel]) + Int(read.pixels[pixel + 1]) + Int(read.pixels[pixel + 2]))
        levels.insert(read.pixels[pixel + 2] / 16)
      }
      #expect(brightest > 90, "something lit: the brightest pixel sums to \(brightest)")
      #expect(levels.count > 2, "more than one flat colour")
    }

    /// Stopped part way, nothing is left behind.
    @Test func aStoppedMovieLeavesNoFile() async throws {
      let folder = try Self.directory()
      defer { try? FileManager.default.removeItem(at: folder) }
      let url = folder.appendingPathComponent("Stopped.mp4")
      var asked = 0
      await #expect(throws: CancellationError.self) {
        try await Movie.write(
          Self.steady(), scene: nil, format: Self.small, device: try Self.device(),
          typesetter: NoTypesetter(),
          to: try MediaFoundationMovie(url: url, format: Self.small)
        ) { done in
          asked += 1
          return done < 0.3
        }
      }
      #expect(!FileManager.default.fileExists(atPath: url.path))
    }
  #endif

  /// Every frame is drawn and written in order, with the sound behind it, and the writer finished;
  /// a format a movie cannot be made in is refused before anything is drawn, and the writer let go.
  @Test func everyFrameIsWrittenAndABadFormatRefused() async throws {
    #if os(Windows)
      let device = try Self.device()
      let kept = Kept()
      try await Movie.write(
        Self.steady(), scene: "pulse", format: Self.small, device: device, typesetter: NoTypesetter(),
        to: kept)
      #expect(kept.frames == Array(0..<75) && kept.bytes == [320 * 180 * 4])
      #expect(kept.samples == 75 * 1600 && kept.finished && !kept.cancelled)
    #endif
    var odd = Self.small
    odd.framesPerSecond = 7
    #expect(!odd.isValid)
    odd = Self.small
    odd.width = 321
    #expect(!odd.isValid, "the encoders want an even size")
  }
}
