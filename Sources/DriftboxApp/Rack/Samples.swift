#if canImport(SwiftUI) && canImport(AVFoundation)
  import AVFoundation
  import DriftboxEngine
  import DriftboxSeq
  import Foundation

  /// What a loaded sample is, for its face: the reference's `SampleInfo`.
  struct SampleInfo: Equatable {
    enum Source { case file, `break` }
    var name: String
    /// Bars the sample is taken to be, which sets the tempo it loops at.
    var bars: Int
    var seconds: Double
    /// Ninety-six peaks, loudest 1, for drawing.
    var peaks: [Double]
    var source: Source
  }

  /// The arithmetic of loading a sample: the reference's `sample.ts`, held to its tests.
  enum SampleMath {
    /// The tempo at which `seconds` of audio is `bars` bars of 4/4.
    static func tempoForBars(_ seconds: Double, _ bars: Int) -> Double {
      guard seconds > 0, bars > 0 else { return 0 }
      return Double(bars) * 4 * 60 / seconds
    }

    /// How many bars — one, two, four or eight — a loop most plausibly is: the count whose tempo is
    /// nearest `tempo`, by ratio.
    static func guessBars(_ seconds: Double, tempo: Double = 120) -> Int {
      guard seconds > 0 else { return 1 }
      var best = 1
      var closest = Double.infinity
      for bars in [1, 2, 4, 8] {
        let distance = abs(log2(tempoForBars(seconds, bars) / max(1, tempo)))
        if distance < closest {
          closest = distance
          best = bars
        }
      }
      return best
    }

    /// Every channel averaged into one.
    static func toMono(_ channels: [[Float]]) -> [Float] {
      guard let first = channels.first else { return [] }
      let count = Float(channels.count)
      var out = [Float](repeating: 0, count: first.count)
      for channel in channels {
        for index in 0..<min(out.count, channel.count) { out[index] += channel[index] / count }
      }
      return out
    }

    /// Scaled so its loudest sample is 0.9; silence left as it is.
    static func normalise(_ samples: [Float]) -> [Float] {
      let peak = samples.reduce(0) { max($0, abs($1)) }
      guard peak > 0 else { return samples }
      let gain = 0.9 / peak
      return samples.map { $0 * gain }
    }

    /// The loudest sample in each of `buckets` stretches, the loudest of them 1.
    static func waveformPeaks(_ samples: [Float], buckets: Int = 96) -> [Double] {
      let count = max(1, buckets)
      var peaks = [Double](repeating: 0, count: count)
      guard !samples.isEmpty else { return peaks }
      var loudest = 0.0
      for bucket in 0..<count {
        let from = bucket * samples.count / count
        let to = max(from + 1, (bucket + 1) * samples.count / count)
        var peak = 0.0
        for index in from..<min(samples.count, to) { peak = max(peak, Double(abs(samples[index]))) }
        peaks[bucket] = peak
        loudest = max(loudest, peak)
      }
      return loudest > 0 ? peaks.map { $0 / loudest } : peaks
    }

    /// A file's name without its extension, sixty characters at most.
    static func name(_ file: String) -> String {
      // The last dot and what follows it, if nothing after it is a dot: the reference's regex.
      var stem = file
      if let dot = file.lastIndex(of: "."), file.index(after: dot) < file.endIndex {
        stem = String(file[..<dot])
      }
      let trimmed = String(stem.prefix(60))
      return trimmed.isEmpty ? "sample" : trimmed
    }

    /// A file's audio, every channel, at `sampleRate`: whatever rate it was recorded at, it plays at
    /// its own pitch in a rack running at this one. (The reference decodes at 44.1kHz whatever the
    /// device runs at, so a file loaded there plays sharp on a 48kHz device; here the rack's rate
    /// is known and fixed.)
    static func decode(_ url: URL, sampleRate: Double) throws -> [[Float]] {
      let file = try AVAudioFile(forReading: url)
      let channels = max(1, Int(file.processingFormat.channelCount))
      guard
        let target = AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels),
          interleaved: false),
        let source = AVAudioPCMBuffer(
          pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(1, file.length)))
      else { throw CocoaError(.fileReadCorruptFile) }
      try file.read(into: source)
      guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
        throw CocoaError(.fileReadUnknown)
      }
      let capacity =
        AVAudioFrameCount(Double(source.frameLength) * sampleRate / file.processingFormat.sampleRate) + 1024
      guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
        throw CocoaError(.fileReadCorruptFile)
      }
      var supplied = false
      var failure: NSError?
      let status = converter.convert(to: output, error: &failure) { _, state in
        if supplied {
          state.pointee = .endOfStream
          return nil
        }
        supplied = true
        state.pointee = .haveData
        return source
      }
      if status == .error { throw failure ?? CocoaError(.fileReadUnknown) }
      guard let data = output.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
      return (0..<channels).map {
        Array(UnsafeBufferPointer(start: data[$0], count: Int(output.frameLength)))
      }
    }
  }

  /// The breaks a patch can be built around, made from the 909 rather than shipped: the reference's
  /// `breaks.ts`, rendered by the native engine as the reference renders them — each voice alone
  /// through the master, summed, the second of two bars kept so the first bar's tails are in it.
  struct RackBreak {
    let id: String
    let name: String
    let tempo: Double
    let tracks: [String: String]

    static let all: [RackBreak] = [
      RackBreak(
        id: "jungle", name: "Jungle", tempo: 174,
        tracks: [
          "909.bd": "X... .... ..X. ....", "909.sd": ".... X..x .... X...", "909.ch": "x.x. x.x. x.x. x.xx",
          "909.oh": "..x. .... ..x. ....",
        ]),
      RackBreak(
        id: "amenish", name: "Chopper", tempo: 174,
        tracks: [
          "909.bd": "X..x ..x. X... ..x.", "909.sd": ".... X.x. ..x. X.xx", "909.ch": "x..x x..x x..x x..x",
          "909.rim": "..x. ...x .x.. x...",
        ]),
      RackBreak(
        id: "roller", name: "Roller", tempo: 174,
        tracks: [
          "909.bd": "X... .... X... ....", "909.sd": ".... X... .... X...", "909.ch": "x.xx x.xx x.xx x.xx",
          "909.rd": "x... x... x... x...",
        ]),
    ]

    static func named(_ id: String) -> RackBreak? { all.first { $0.id == id } }

    /// Frames in a bar of 4/4 at `tempo`.
    static func barFrames(_ tempo: Double, _ sampleRate: Double) -> Int {
      Int(RackDisplay.jsRound(sampleRate * 60 * 4 / tempo))
    }

    /// `X` an accent, `x` a hit, anything else a rest; spaces are for reading.
    static func steps(_ line: String) -> [StepValue] {
      line.filter { !$0.isWhitespace }.map { $0 == "X" ? .accent : $0 == "x" ? .on : .off }
    }

    var song: Song {
      var pattern = DriftboxSeq.Pattern(id: "break", name: name, length: 16)
      for (voice, line) in tracks { pattern.tracks[voice] = Self.steps(line) }
      var song = Song(bpm: tempo, patterns: [pattern])
      song.swing = 0
      song.chain = [ChainStep(pattern: "break", repeat: 2)]
      return song
    }

    /// One bar of the break at `sampleRate`, mono, its loudest sample 0.9.
    func render(sampleRate: Double) -> [Float] {
      let perBar = Self.barFrames(tempo, sampleRate)
      var out = [Float](repeating: 0, count: perBar)
      for voice in tracks.keys.sorted() {
        var options = SongRenderer.Options(sampleRate: sampleRate, tail: 1)
        options.only = [voice]
        let stem = SongRenderer.render(song, options: options)
        for i in 0..<perBar {
          let at = perBar + i
          if at < stem.left.count { out[i] += stem.left[at] / 2 }
          if at < stem.right.count { out[i] += stem.right[at] / 2 }
        }
      }
      return SampleMath.normalise(out)
    }
  }
#endif
