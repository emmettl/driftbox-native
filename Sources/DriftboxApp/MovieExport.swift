#if canImport(AVFoundation) && canImport(Metal)
  import AVFoundation
  import CoreMedia
  import CoreVideo
  import DriftboxEngine
  import DriftboxHost
  import DriftboxScenes
  import DriftboxSeq
  import DriftboxSession
  import Foundation
  import Metal

  /// A song and its visuals, written to a movie: the picture and the sound from one pass of an
  /// engine of its own, so they cannot drift apart, rendered as fast as the machine goes rather
  /// than as the song plays, so what is written is exact however long it takes.
  ///
  /// Each frame is what the visuals would show at that moment of a live performance: an
  /// `EngineHost` renders the audio up to it, a `Session` over the host turns what the engine has
  /// played into the scene's input — the same `sceneInput` the app draws from — and a renderer of
  /// its own draws the scene offscreen. Its own, not the app's, because whoever draws takes the
  /// engine's events, and the live visuals would lose them to the movie.
  @MainActor
  enum MovieExport {
    struct Format: Equatable {
      var width = 1920
      var height = 1080
      /// Frames a second. The sample rate divides by it, so every frame has a whole number of
      /// samples of sound behind it.
      var framesPerSecond = 60
      var sampleRate = 48000
      /// Seconds after the song ends, for its tails to ring out.
      var tailSeconds = 2.0

      var samplesPerFrame: Int { sampleRate / framesPerSecond }
      /// What a scene's lines and type are sized by: the visuals window's own is 540 points tall.
      var pixelRatio: Float { Float(height) / 540 }
    }

    enum Failure: Error, Equatable {
      case noGPU
      case format
      case writer(String)
    }

    /// Write `song`, seen as `scene` — or the scene it names, for nil — to `url`, replacing what is
    /// there: played once from the top and left to ring out, as a take nobody played. `progress`
    /// hears how far it has got, from 0 to 1, and stops it by answering false, when the half-written
    /// file is taken away and `CancellationError` thrown.
    static func write(
      _ song: Song, scene: String?, to url: URL, format: Format = Format(),
      progress: (Double) -> Bool = { _ in true }
    ) async throws {
      try await write(
        Take.song(song, sampleRate: Double(format.sampleRate), tail: format.tailSeconds), scene: scene,
        to: url,
        format: format, progress: progress)
    }

    /// Write a performance, played again on an engine of its own, to `url`: what was heard and seen,
    /// seen as `scene` throughout if one is given, or as the take saw it if not.
    static func write(
      _ take: Take, scene: String? = nil, to url: URL, format: Format = Format(),
      progress: (Double) -> Bool = { _ in true }
    ) async throws {
      guard format.width > 0, format.height > 0, format.framesPerSecond > 0,
        format.sampleRate % format.framesPerSecond == 0, take.sampleRate == Double(format.sampleRate)
      else { throw Failure.format }

      // The performance first: nothing is written until it has been played through.
      let played = try await perform(take, scene: scene, format: format, progress: { progress(0.1 * $0) })
      let (inputs, left, right, frames, chunk) = (
        played.inputs, played.left, played.right, played.inputs.count, format.samplesPerFrame
      )
      var scenes = played.scenes

      // The picture: a renderer of its own, drawing into a frame the CPU can read back.
      let renderer: SceneRenderer
      do {
        renderer = try SceneRenderer(sceneId: scene ?? take.scene ?? take.song.visual, now: 0)
      } catch {
        throw Failure.noGPU
      }
      guard let target = Self.frame(format, on: renderer.device) else { throw Failure.noGPU }

      try? FileManager.default.removeItem(at: url)
      let writer: AVAssetWriter
      do {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
      } catch {
        throw Failure.writer(error.localizedDescription)
      }
      let video = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(format))
      video.expectsMediaDataInRealTime = false
      let pixels = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: video,
        sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
          kCVPixelBufferWidthKey as String: format.width, kCVPixelBufferHeightKey as String: format.height,
        ])
      let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(format))
      audio.expectsMediaDataInRealTime = false
      guard writer.canAdd(video), writer.canAdd(audio) else { throw Failure.writer("cannot add the tracks") }
      writer.add(video)
      writer.add(audio)
      guard writer.startWriting() else {
        throw Failure.writer(writer.error?.localizedDescription ?? "cannot start writing")
      }
      writer.startSession(atSourceTime: .zero)
      guard let pcm = Self.pcmFormat(format) else { throw Failure.format }

      // Then the movie: each track fed as the writer will take it. It interleaves them, and stops
      // taking one until the other has caught up — the sound's encoder holds some back — so neither
      // may wait on the other; the sound is all there, and a picture is drawn when it is wanted.
      var picture = 0
      var sound = 0
      do {
        var idle = 0
        while picture < frames || sound < frames {
          var moved = false
          if picture < frames, video.isReadyForMoreMediaData {
            while let first = scenes.first, first.from <= picture {
              try? renderer.show(first.id ?? take.song.visual)
              scenes.removeFirst()
            }
            renderer.draw(inputs[picture], into: target)
            guard
              let buffer = try Self.pixelBuffer(of: target, renderer: renderer, pool: pixels.pixelBufferPool)
            else { throw Failure.writer("no pixel buffer") }
            pixels.append(
              buffer,
              withPresentationTime: CMTime(value: Int64(picture), timescale: Int32(format.framesPerSecond)))
            picture += 1
            moved = true
            if picture == frames { video.markAsFinished() }
          }
          while sound < frames, audio.isReadyForMoreMediaData {
            let buffer = try left.withUnsafeBufferPointer { l in
              try right.withUnsafeBufferPointer { r in
                try Self.audioBuffer(
                  left: l.baseAddress! + sound * chunk, right: r.baseAddress! + sound * chunk, frames: chunk,
                  startingAt: sound * chunk, format: pcm, sampleRate: format.sampleRate)
              }
            }
            audio.append(buffer)
            sound += 1
            moved = true
            // Said at once: the writer holds the pictures back for sound past the last until it is
            // told none is coming.
            if sound == frames { audio.markAsFinished() }
          }
          if let failure = writer.error { throw Failure.writer(failure.localizedDescription) }
          if moved {
            idle = 0
            guard progress(0.1 + 0.9 * Double(picture) / Double(frames)) else { throw CancellationError() }
            // Let the window draw between frames: a long song is minutes of this.
            await Task.yield()
          } else {
            idle += 1
            // Ten seconds of the writer taking nothing is a writer that has stopped.
            if idle > 10_000 { throw Failure.writer("the encoders stopped taking what they were given") }
            try await Task.sleep(for: .milliseconds(1))
          }
        }
      } catch {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
        throw error
      }
      await writer.finishWriting()
      guard writer.status == .completed else {
        throw Failure.writer(writer.error?.localizedDescription ?? "the movie was not finished")
      }
    }

    /// A take played again: its sound, and what the scene is fed at each frame and which scene it
    /// shows from when. Played on an engine of its own, the engine set as the take found the one it
    /// was played on, and everything done to it done again at the frame it took effect on.
    struct Performance {
      var inputs: [SceneInput]
      var scenes: [(from: Int, id: String?)]
      var left: [Float]
      var right: [Float]
    }

    static func perform(
      _ take: Take, scene: String? = nil, format: Format, progress: (Double) -> Bool = { _ in true }
    ) async throws -> Performance {
      // Up to two seconds of the song leading into where the take began, to be played and thrown
      // away: the take began with the song's notes and tails already sounding, and they arrive with
      // it. The engine's clock starts that far before the take's, so it reaches the take's start on
      // the frame the live one did.
      let preroll = take.playing ? min(take.songFrame, Int(2 * take.sampleRate)) : 0
      let host = EngineHost(sampleRate: Double(format.sampleRate), clock: take.start - preroll)
      let session = Session(host: host)
      session.open(take.song, named: "Movie")
      if let loop = take.loop { host.send(.loop(startBar: loop.start, bars: loop.bars)) }
      if take.metronome { host.send(.metronome(true)) }
      if take.playing {
        host.send(.seek(songFrame: take.songFrame - preroll))
        host.send(.play)
        let discard = UnsafeMutablePointer<Float>.allocate(capacity: 2 * max(1, preroll))
        defer { discard.deallocate() }
        if preroll > 0 { host.render(frames: preroll, left: discard, right: discard + preroll) }
      } else if take.songFrame > 0 {
        host.send(.seek(songFrame: take.songFrame))
      }
      let chunk = format.samplesPerFrame
      let frames = max(1, Int((Double(take.end - take.start) / Double(chunk)).rounded(.up)))

      // First, the performance: the engine through the whole take, keeping the sound, and what the
      // scene would have been fed at each frame's moment — everything rendered up to it. A frame's
      // input is small; its picture is megabytes, so pictures are drawn only as the writer takes them.
      var inputs: [SceneInput] = []
      inputs.reserveCapacity(frames)
      // Which scene to show from which frame on, when the take switched and no one scene was asked for.
      var scenes: [(from: Int, id: String?)] = []
      var left = [Float](repeating: 0, count: frames * chunk)
      var right = [Float](repeating: 0, count: frames * chunk)
      var next = 0
      /// Render `count` frames of sound into the movie's, `at` frames in.
      func render(_ count: Int, at: Int) {
        guard count > 0 else { return }
        left.withUnsafeMutableBufferPointer { l in
          right.withUnsafeMutableBufferPointer { r in
            host.render(frames: count, left: l.baseAddress! + at, right: r.baseAddress! + at)
          }
        }
      }
      for index in 0..<frames {
        session.tick()
        inputs.append(
          session.sceneInput(
            time: Double(index) / Double(format.framesPerSecond), pixelRatio: format.pixelRatio))
        // Then the sound between this frame and the next, stopping at each thing done to the engine
        // in it, at the frame it was done on.
        let from = take.start + index * chunk
        var done = 0
        while next < take.events.count, take.events[next].frame < from + chunk {
          let (frame, event) = take.events[next]
          let at = min(chunk, max(done, frame - from))
          render(at - done, at: index * chunk + done)
          done = at
          switch event {
          // The pad through the session, which draws where it is touched.
          case .command(.pad(let x, let y)): session.pad(x: x, y: y)
          case .command(.padRelease): session.padRelease()
          case .command(let command): host.send(command)
          case .song(let song, let keepingPlace): session.takeUp(song, keepingPlace: keepingPlace)
          case .scene(let id): if scene == nil { scenes.append((index + 1, id)) }
          }
          next += 1
        }
        render(chunk - done, at: index * chunk + done)
        // A chance for the window to draw.
        if index % 30 == 0 {
          guard progress(Double(index) / Double(frames)) else { throw CancellationError() }
          await Task.yield()
        }
      }

      return Performance(inputs: inputs, scenes: scenes, left: left, right: right)
    }

    // MARK: - Picture

    /// A frame the size of the movie, drawn into by the GPU and read back by the CPU: shared where
    /// the two share memory, managed where they do not.
    static func frame(_ format: Format, on device: MTLDevice) -> MTLTexture? {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: format.width, height: format.height, mipmapped: false)
      descriptor.usage = [.renderTarget, .shaderRead]
      descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
      return device.makeTexture(descriptor: descriptor)
    }

    /// The frame just drawn, once the GPU has finished it, copied into a pixel buffer for the movie.
    static func pixelBuffer(of target: MTLTexture, renderer: SceneRenderer, pool: CVPixelBufferPool?) throws
      -> CVPixelBuffer?
    {
      // An empty command buffer after the frame's, waited on: the queue runs them in order.
      guard let wait = renderer.queue.makeCommandBuffer() else { return nil }
      if target.storageMode == .managed, let blit = wait.makeBlitCommandEncoder() {
        blit.synchronize(resource: target)
        blit.endEncoding()
      }
      wait.commit()
      wait.waitUntilCompleted()
      guard let pool else { return nil }
      var made: CVPixelBuffer?
      guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else {
        return nil
      }
      CVPixelBufferLockBaseAddress(buffer, [])
      defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
      guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
      target.getBytes(
        base, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
      return buffer
    }

    static func videoSettings(_ format: Format) -> [String: Any] {
      // A little over a tenth of a bit a pixel a frame: plenty for scenes that are mostly smooth
      // colour moving fast, which is what starves an encoder of bits.
      let bits = Double(format.width * format.height * format.framesPerSecond) * 0.12
      return [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: format.width,
        AVVideoHeightKey: format.height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: Int(bits), AVVideoMaxKeyFrameIntervalKey: format.framesPerSecond * 2,
        ],
      ]
    }

    // MARK: - Sound

    static func audioSettings(_ format: Format) -> [String: Any] {
      [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 256_000,
      ]
    }

    /// Two channels of floats, interleaved: what the engine's blocks are handed to the writer as.
    static func pcmFormat(_ format: Format) -> CMAudioFormatDescription? {
      var description = AudioStreamBasicDescription(
        mSampleRate: Double(format.sampleRate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
        mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
      var made: CMAudioFormatDescription?
      CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &made)
      return made
    }

    /// One block of the engine's sound as a sample buffer, stamped at `start` samples in.
    static func audioBuffer(
      left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, startingAt start: Int,
      format: CMAudioFormatDescription, sampleRate: Int
    ) throws -> CMSampleBuffer {
      let bytes = frames * 8
      var block: CMBlockBuffer?
      guard
        CMBlockBufferCreateWithMemoryBlock(
          allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
          offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
          == kCMBlockBufferNoErr, let block
      else { throw Failure.writer("no memory for the sound") }
      var interleaved = [Float](repeating: 0, count: frames * 2)
      for frame in 0..<frames {
        interleaved[frame * 2] = left[frame]
        interleaved[frame * 2 + 1] = right[frame]
      }
      let copied = interleaved.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(
          with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
      }
      guard copied == kCMBlockBufferNoErr else { throw Failure.writer("could not copy the sound") }
      var sample: CMSampleBuffer?
      guard
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
          allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
          presentationTimeStamp: CMTime(value: Int64(start), timescale: Int32(sampleRate)),
          packetDescriptions: nil, sampleBufferOut: &sample) == noErr, let sample
      else { throw Failure.writer("could not make the sound's buffer") }
      return sample
    }

  }
#endif
