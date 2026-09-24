#if canImport(AVFoundation) && canImport(Metal)
  import AVFoundation
  import DriftboxSeq
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// A song and its visuals written to a movie, and read back: the tracks, the length, the sound
  /// and the picture are what was asked for.
  @MainActor
  struct MovieExportTests {
    /// Small and short, so the test is quick: a pass of `steadySong` is two seconds.
    static let small = MovieExport.Format(
      width: 320, height: 180, framesPerSecond: 30, sampleRate: 48000, tailSeconds: 0.5)

    static func written(_ song: Song = steadySong(), in directory: URL) async throws -> URL {
      let url = directory.appendingPathComponent("Steady.mov")
      try await MovieExport.write(song, scene: nil, to: url, format: small)
      return url
    }

    @Test func theMovieHasTheSongsPictureAndSound() async throws {
      try await withTemporaryDirectoryAsync { directory in
        let url = try await Self.written(in: directory)
        let asset = AVURLAsset(url: url)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let size = try await video.load(.naturalSize)
        #expect(size == CGSize(width: 320, height: 180))
        let rate = try await video.load(.nominalFrameRate)
        #expect(abs(rate - 30) < 0.5, "\(rate) frames a second")
        // The song's two seconds, and half a second of tail.
        let seconds = try await asset.load(.duration).seconds
        #expect(abs(seconds - 2.5) < 0.1, "\(seconds) seconds")
        let channels = try await audio.load(.formatDescriptions).first
          .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
        #expect(channels == 2)
      }
    }

    /// The kick on every step is heard while the song plays, and only its tail after.
    @Test func theSoundIsTheSong() async throws {
      try await withTemporaryDirectoryAsync { directory in
        let url = try await Self.written(in: directory)
        let samples = try await Self.decoded(url)
        let rate = 48000
        func rms(_ range: Range<Int>) -> Double {
          let slice = samples[max(0, range.lowerBound)..<min(samples.count, range.upperBound)]
          return (slice.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, slice.count))).squareRoot()
        }
        let playing = rms(rate / 2..<rate * 3 / 2)
        let after = rms(rate * 2 + rate / 5..<rate * 5 / 2)
        #expect(playing > 0.02, "\(playing) while it plays")
        #expect(after < playing * 0.5, "\(after) after, against \(playing)")
      }
    }

    /// A frame from the middle has something drawn on it, not a blank.
    @Test func thePictureIsTheScene() async throws {
      try await withTemporaryDirectoryAsync { directory in
        let url = try await Self.written(in: directory)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        #expect(image.width == 320 && image.height == 180)
        let context = try #require(
          CGContext(
            data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 320 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 320, height: 180))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var brightest = 0
        var levels = Set<UInt8>()
        for pixel in 0..<(320 * 180) {
          let r = data[pixel * 4]
          let g = data[pixel * 4 + 1]
          let b = data[pixel * 4 + 2]
          brightest = max(brightest, Int(r) + Int(g) + Int(b))
          levels.insert(r / 16)
        }
        #expect(brightest > 90, "something lit: the brightest pixel sums to \(brightest)")
        #expect(levels.count > 2, "more than one flat colour")
      }
    }

    /// Stopped part way, nothing is left behind.
    @Test func aCancelledMovieLeavesNoFile() async throws {
      try await withTemporaryDirectoryAsync { directory in
        let url = directory.appendingPathComponent("Cancelled.mov")
        var frames = 0
        await #expect(throws: CancellationError.self) {
          try await MovieExport.write(steadySong(), scene: nil, to: url, format: Self.small) { _ in
            frames += 1
            return frames < 5
          }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
      }
    }

    @Test func aFrameRateThatDoesNotDivideTheSoundIsRefused() async throws {
      var odd = Self.small
      odd.framesPerSecond = 7
      await #expect(throws: MovieExport.Failure.format) {
        try await MovieExport.write(
          steadySong(), scene: nil, to: URL(fileURLWithPath: "/tmp/never.mov"), format: odd)
      }
    }

    /// From the stage, as the File menu starts it: the song being shown, written while the app goes
    /// on, then handed on; and stopped part way, nothing left and nothing handed on.
    @Test func theStageWritesTheSongItIsShowing() async throws {
      try await withTemporaryDirectoryAsync { directory in
        let (player, _) = try openedPlayer(steadySong(), in: directory)
        let stage = Stage(player: player)
        stage.movieFormat = Self.small
        var revealed: [URL] = []
        stage.reveal = { revealed.append($0) }
        let url = directory.appendingPathComponent("Shown.mov")
        stage.exportMovie(to: url)
        #expect(stage.exporting == 0)
        var seen: Set<Int> = []
        for _ in 0..<3000 where stage.exporting != nil {
          seen.insert(Int((stage.exporting ?? 1) * 10))
          try await Task.sleep(for: .milliseconds(10))
        }
        #expect(stage.exporting == nil)
        #expect(stage.exportFailure == nil)
        #expect(revealed == [url])
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(seen.count > 3, "progress moved through \(seen.sorted())")

        let stopped = directory.appendingPathComponent("Stopped.mov")
        stage.exportMovie(to: stopped)
        stage.stopExport()
        for _ in 0..<3000 where stage.exporting != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!FileManager.default.fileExists(atPath: stopped.path))
        #expect(revealed == [url], "a stopped movie is not handed on")
        #expect(stage.exportFailure == nil, "stopping is not a failure")
      }
    }

    /// The movie's sound, decoded to one channel of floats: the left.
    static func decoded(_ url: URL) async throws -> [Float] {
      let asset = AVURLAsset(url: url)
      let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
          AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
      reader.add(output)
      reader.startReading()
      var left: [Float] = []
      while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(
          block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
        guard let pointer else { continue }
        let floats = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
        for frame in 0..<(length / 8) { left.append(floats[frame * 2]) }
      }
      return left
    }
  }

  /// `withTemporaryDirectory`, for a test that awaits.
  @MainActor
  func withTemporaryDirectoryAsync<T>(_ body: (URL) async throws -> T) async rethrows -> T {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("driftbox-app-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
  }
#endif
