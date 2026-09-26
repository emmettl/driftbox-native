import DriftboxEngine
import DriftboxGPU
import DriftboxHost
import DriftboxScenes
import DriftboxSeq
import DriftboxSession
import DriftboxText

/// A performance and its visuals, as a movie, on any platform with the GPU layer: the picture and
/// the sound from one pass of an engine of its own, so they cannot drift apart, rendered as fast as
/// the machine goes rather than as the song plays, so what is written is exact however long it
/// takes. What writes the file is the platform's `MovieWriter`.
///
/// Each frame is what the visuals would show at that moment of a live performance: an `EngineHost`
/// renders the sound up to it, a `Session` over the host turns what the engine has played into the
/// scene's input — the same `sceneInput` the app draws from — and a scene of its own draws it
/// offscreen. Its own, not the app's, because whoever draws takes the engine's events, and the live
/// visuals would lose them to the movie. The Mac's `MovieExport` does the same through
/// AVFoundation and Metal.
public struct MovieFormat: Equatable, Sendable {
  public var width = 1920
  public var height = 1080
  /// Frames a second. The sample rate divides by it, so every frame has a whole number of samples
  /// of sound behind it.
  public var framesPerSecond = 60
  public var sampleRate = 48000
  /// Seconds after the song ends, for its tails to ring out.
  public var tailSeconds = 2.0

  public init(
    width: Int = 1920, height: Int = 1080, framesPerSecond: Int = 60, sampleRate: Int = 48000,
    tailSeconds: Double = 2
  ) {
    self.width = width
    self.height = height
    self.framesPerSecond = framesPerSecond
    self.sampleRate = sampleRate
    self.tailSeconds = tailSeconds
  }

  public var samplesPerFrame: Int { sampleRate / framesPerSecond }
  /// What a scene's lines and type are sized by: the visuals window's own is 540 points tall.
  public var pixelRatio: Float { Float(height) / 540 }
  /// A little over a tenth of a bit a pixel a frame: plenty for scenes that are mostly smooth colour
  /// moving fast, which is what starves an encoder of bits. The Mac's, too.
  public var videoBitRate: Int { Int(Double(width * height * framesPerSecond) * 0.12) }
  /// Whether a movie can be made in it: a positive size, even for the encoders, and a frame rate the
  /// sample rate divides by.
  public var isValid: Bool {
    width > 0 && height > 0 && width % 2 == 0 && height % 2 == 0 && framesPerSecond > 0
      && sampleRate % framesPerSecond == 0
  }
}

public enum MovieFailure: Error, Equatable, CustomStringConvertible {
  /// A format a movie cannot be made in, or a take at another rate.
  case format
  /// The GPU would not draw it.
  case picture(String)
  case writer(String)

  public var description: String {
    switch self {
    case .format: "The movie's size or rates will not do"
    case .picture(let why): "The picture could not be drawn: \(why)"
    case .writer(let why): "The movie could not be written: \(why)"
    }
  }
}

/// What writes a movie's file: frame by frame, its picture and the sound behind it.
@MainActor
public protocol MovieWriter: AnyObject {
  /// Frame `frame`'s picture: the format's width by height in BGRA, rows from the top.
  func appendVideo(_ pixels: [UInt8], frame: Int) throws
  /// `frames` of stereo sound starting `start` samples in.
  func appendAudio(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, start: Int) throws
  /// The file, finished.
  func finish() throws
  /// Stopped part way: the file taken away.
  func cancel()
}

@MainActor
public enum Movie {
  /// A take played again: its sound, and what the scene is fed at each frame and which scene it
  /// shows from when.
  public struct Performance {
    public var inputs: [SceneInput]
    public var scenes: [(from: Int, id: String?)]
    public var left: [Float]
    public var right: [Float]
  }

  /// Write `take` through `writer`, seen as `scene` throughout, or as the take saw it for nil: drawn
  /// on `device` with `typesetter`'s type. `progress` hears how far it has got, from 0 to 1, and stops
  /// it by answering false, when the writer is cancelled and `CancellationError` thrown. Now and
  /// then it lets the app's window draw.
  public static func write(
    _ take: Take, scene: String? = nil, format: MovieFormat, device: any GPUDevice,
    typesetter: any Typesetter, to writer: any MovieWriter, progress: (Double) -> Bool = { _ in true }
  ) async throws {
    do {
      guard format.isValid, take.sampleRate == Double(format.sampleRate) else { throw MovieFailure.format }
      // The performance first: nothing is written until it has been played through.
      let played = try await perform(take, scene: scene, format: format, progress: { progress(0.1 * $0) })
      let target: any GPUTarget
      var drawing: any GPUScene
      var shown = GPUScenes.type(for: scene ?? take.scene ?? take.song.visual)
      do {
        target = try device.makeTarget(width: format.width, height: format.height)
        drawing = try shown.init(device: device, typesetter: typesetter)
      } catch {
        throw MovieFailure.picture("\(error)")
      }
      let frames = played.inputs.count
      let chunk = format.samplesPerFrame
      var switches = played.scenes[...]
      var since = ContinuousClock.now
      for frame in 0..<frames {
        while let next = switches.first, next.from <= frame {
          let wanted = GPUScenes.type(for: next.id ?? take.song.visual)
          if wanted.id != shown.id, let made = try? wanted.init(device: device, typesetter: typesetter) {
            drawing = made
            shown = wanted
          }
          switches.removeFirst()
        }
        drawing.draw(played.inputs[frame], into: target, on: device)
        try writer.appendVideo(try device.readPixels(target), frame: frame)
        try played.left.withUnsafeBufferPointer { left in
          try played.right.withUnsafeBufferPointer { right in
            try writer.appendAudio(
              left: left.baseAddress! + frame * chunk, right: right.baseAddress! + frame * chunk,
              frames: chunk,
              start: frame * chunk)
          }
        }
        guard progress(0.1 + 0.9 * Double(frame + 1) / Double(frames)) else { throw CancellationError() }
        // The app's window draws between frames every so often: a long song is minutes of this.
        if since.duration(to: .now) > .milliseconds(12) {
          await Task.yield()
          since = .now
        }
      }
      try writer.finish()
    } catch {
      writer.cancel()
      throw error
    }
  }

  /// A song played once from the top and left to ring out, as a take nobody played.
  public static func write(
    _ song: Song, scene: String?, format: MovieFormat, device: any GPUDevice, typesetter: any Typesetter,
    to writer: any MovieWriter, progress: (Double) -> Bool = { _ in true }
  ) async throws {
    try await write(
      Take.song(song, sampleRate: Double(format.sampleRate), tail: format.tailSeconds), scene: scene,
      format: format, device: device, typesetter: typesetter, to: writer, progress: progress)
  }

  /// A take played again on an engine of its own, the engine set as the take found the one it was
  /// played on, and everything done to it done again at the frame it took effect on.
  public static func perform(
    _ take: Take, scene: String? = nil, format: MovieFormat, progress: (Double) -> Bool = { _ in true }
  ) async throws -> Performance {
    // Up to two seconds of the song leading into where the take began, to be played and thrown away:
    // the take began with the song's notes and tails already sounding, and they arrive with it. The
    // engine's clock starts that far before the take's, so it reaches the take's start on the frame
    // the live one did.
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

    // The engine through the whole take, keeping the sound, and what the scene would have been fed
    // at each frame's moment — everything rendered up to it. A frame's input is small; its picture
    // is megabytes, so pictures are drawn only as they are written.
    var inputs: [SceneInput] = []
    inputs.reserveCapacity(frames)
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
      // Then the sound between this frame and the next, stopping at each thing done to the engine in
      // it, at the frame it was done on.
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
      if index % 30 == 0 {
        guard progress(Double(index) / Double(frames)) else { throw CancellationError() }
        await Task.yield()
      }
    }
    return Performance(inputs: inputs, scenes: scenes, left: left, right: right)
  }
}
