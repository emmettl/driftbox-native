#if os(Windows)
  import CMovieWriter
  import Foundation

  /// Windows' movies: an H.264 and AAC MPEG-4 file, written through Media Foundation.
  @MainActor
  public final class MediaFoundationMovie: MovieWriter {
    public let url: URL
    private var movie: OpaquePointer?

    /// A movie at `url`, replacing what is there, in `format`.
    public init(url: URL, format: MovieFormat) throws {
      guard format.isValid else { throw MovieFailure.format }
      try? FileManager.default.removeItem(at: url)
      var error = [CChar](repeating: 0, count: 512)
      guard
        let opened = dbmovie_open(
          url.path, Int32(format.width), Int32(format.height), Int32(format.framesPerSecond),
          Int32(format.sampleRate), Int32(format.videoBitRate), &error, error.count)
      else { throw MovieFailure.writer(Self.string(error)) }
      self.url = url
      movie = opened
    }

    public func appendVideo(_ pixels: [UInt8], frame: Int) throws {
      guard let movie, dbmovie_video(movie, pixels, Int64(frame)) else {
        throw MovieFailure.writer("the picture's frame \(frame) was not taken")
      }
    }

    public func appendAudio(
      left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, start: Int
    ) throws {
      guard let movie, dbmovie_audio(movie, left, right, Int32(frames), Int64(start)) else {
        throw MovieFailure.writer("the sound at \(start) was not taken")
      }
    }

    public func finish() throws {
      guard let finishing = movie else { return }
      movie = nil
      var error = [CChar](repeating: 0, count: 512)
      guard dbmovie_finish(finishing, &error, error.count) else {
        try? FileManager.default.removeItem(at: url)
        throw MovieFailure.writer(Self.string(error))
      }
    }

    public func cancel() {
      if let movie { dbmovie_cancel(movie) }
      movie = nil
      try? FileManager.default.removeItem(at: url)
    }

    /// Let go of unfinished, as when writing it threw: nothing half-written left behind.
    isolated deinit { if movie != nil { cancel() } }

    nonisolated static func string(_ characters: [CChar]) -> String {
      String(decoding: characters.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
  }

  /// What a movie file holds, as Media Foundation reads it back: for the tests, and anything that
  /// wants to know what was written.
  public struct MovieContents: Equatable, Sendable {
    public var seconds: Double
    public var width: Int
    public var height: Int
    public var framesPerSecond: Double
    public var sampleRate: Int
    public var channels: Int
    /// The loudest sample, and the level, of the sound between the times asked about.
    public var peak: Float
    public var rms: Float
    /// The picture at the time asked about, BGRA rows from the top, when one was asked for.
    public var pixels: [UInt8]

    /// The movie at `url`: its sound between `from` and `to` seconds, and, with `picture`, the
    /// frame showing at `at`.
    public static func read(
      _ url: URL, soundFrom from: Double = 0, to: Double = .infinity, pictureAt at: Double? = nil
    ) throws -> MovieContents {
      var info = DBMovieInfo()
      var error = [CChar](repeating: 0, count: 512)
      // Its size is known only once it is read: read once for it, again for the picture.
      guard dbmovie_probe(url.path, from, to, 0, nil, &info, &error, error.count) else {
        throw MovieFailure.writer(MediaFoundationMovie.string(error))
      }
      var pixels: [UInt8] = []
      if let at, info.width > 0, info.height > 0 {
        pixels = [UInt8](repeating: 0, count: Int(info.width) * Int(info.height) * 4)
        guard dbmovie_probe(url.path, from, to, at, &pixels, &info, &error, error.count) else {
          throw MovieFailure.writer(MediaFoundationMovie.string(error))
        }
      }
      return MovieContents(
        seconds: info.seconds, width: Int(info.width), height: Int(info.height),
        framesPerSecond: info.framesPerSecond, sampleRate: Int(info.sampleRate), channels: Int(info.channels),
        peak: info.peak, rms: info.rms, pixels: pixels)
    }
  }
#endif
