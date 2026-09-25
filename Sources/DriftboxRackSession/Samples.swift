// Decoding is a port here, where the Mac app read files with AVFoundation: `WAVDecoder` answers
// it on every platform.
import DriftboxEngine
import DriftboxSeq
import Foundation

/// What a loaded sample is, for its face: the reference's `SampleInfo`.
public struct SampleInfo: Equatable, Sendable {
  public enum Source: Sendable { case file, `break` }
  public var name: String
  /// Bars the sample is taken to be, which sets the tempo it loops at.
  public var bars: Int
  public var seconds: Double
  /// Ninety-six peaks, loudest 1, for drawing.
  public var peaks: [Double]
  public var source: Source

  public init(name: String, bars: Int, seconds: Double, peaks: [Double], source: Source) {
    self.name = name
    self.bars = bars
    self.seconds = seconds
    self.peaks = peaks
    self.source = source
  }
}

/// A file's audio, every channel, at the rack's rate: the port a platform answers, the Mac with
/// AVFoundation and every platform with `WAVDecoder`.
public protocol SampleDecoding: Sendable {
  /// A file's audio, every channel, at `sampleRate`: whatever rate it was recorded at, it plays at
  /// its own pitch in a rack running at this one. (The reference decodes at 44.1kHz whatever the
  /// device runs at, so a file loaded there plays sharp on a 48kHz device; here the rack's rate
  /// is known and fixed.)
  func decode(_ url: URL, sampleRate: Double) throws -> [[Float]]

  /// What it reads, as a prompt to choose a file says: "a WAV file", unless it reads more.
  var readable: String { get }
}

extension SampleDecoding {
  public var readable: String { "a WAV file" }
}

/// The arithmetic of loading a sample: the reference's `sample.ts`, held to its tests.
public enum SampleMath {
  /// The tempo at which `seconds` of audio is `bars` bars of 4/4.
  public static func tempoForBars(_ seconds: Double, _ bars: Int) -> Double {
    guard seconds > 0, bars > 0 else { return 0 }
    return Double(bars) * 4 * 60 / seconds
  }

  /// How many bars — one, two, four or eight — a loop most plausibly is: the count whose tempo is
  /// nearest `tempo`, by ratio.
  public static func guessBars(_ seconds: Double, tempo: Double = 120) -> Int {
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
  public static func toMono(_ channels: [[Float]]) -> [Float] {
    guard let first = channels.first else { return [] }
    let count = Float(channels.count)
    var out = [Float](repeating: 0, count: first.count)
    for channel in channels {
      for index in 0..<min(out.count, channel.count) { out[index] += channel[index] / count }
    }
    return out
  }

  /// Scaled so its loudest sample is 0.9; silence left as it is.
  public static func normalise(_ samples: [Float]) -> [Float] {
    let peak = samples.reduce(0) { max($0, abs($1)) }
    guard peak > 0 else { return samples }
    let gain = 0.9 / peak
    return samples.map { $0 * gain }
  }

  /// The loudest sample in each of `buckets` stretches, the loudest of them 1.
  public static func waveformPeaks(_ samples: [Float], buckets: Int = 96) -> [Double] {
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
  public static func name(_ file: String) -> String {
    // The last dot and what follows it, if nothing after it is a dot: the reference's regex.
    var stem = file
    if let dot = file.lastIndex(of: "."), file.index(after: dot) < file.endIndex {
      stem = String(file[..<dot])
    }
    let trimmed = String(stem.prefix(60))
    return trimmed.isEmpty ? "sample" : trimmed
  }
}

/// Why `WAVDecoder` could not read a file.
public enum WAVDecodingError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
  /// Not a RIFF file of type WAVE at all.
  case notWAV
  /// A WAVE file with no `fmt ` chunk, or one too short to say what the audio is.
  case missingFormat
  /// A WAVE file with no `data` chunk.
  case missingData
  /// Audio in an encoding this decoder does not read: compressed, or a sample of an unusual size.
  case unsupported(formatTag: Int, bitsPerSample: Int)
  /// A format that contradicts itself.
  case malformed(String)

  public var description: String {
    switch self {
    case .notWAV: "Not a WAV file."
    case .missingFormat: "A WAV file that does not say what its audio is."
    case .missingData: "A WAV file with no audio in it."
    case .unsupported(let tag, let bits):
      "A WAV file in an encoding this build cannot read (format \(tag), \(bits)-bit)."
    case .malformed(let reason): "A WAV file that is damaged: \(reason)."
    }
  }

  public var errorDescription: String? { description }
}

/// WAV files, in Swift alone, so that every platform can load a sample: integer PCM of 8, 16, 24
/// or 32 bits and floating point of 32 or 64, plain or in the extensible header, any number of
/// channels, taken to the rack's rate by a straight line between neighbouring samples.
public struct WAVDecoder: SampleDecoding {
  public init() {}

  public func decode(_ url: URL, sampleRate: Double) throws -> [[Float]] {
    try decode(Data(contentsOf: url), sampleRate: sampleRate)
  }

  /// The same, from a file's bytes.
  public func decode(_ data: Data, sampleRate: Double) throws -> [[Float]] {
    let (rate, channels) = try data.withUnsafeBytes { try Self.read(Bytes(raw: $0)) }
    guard sampleRate > 0, rate != sampleRate else { return channels }
    return channels.map { Self.resample($0, from: rate, to: sampleRate) }
  }

  /// `samples` recorded at `from` frames a second, as they would have been at `to`: each new
  /// sample on the straight line between the two old ones either side of it.
  public static func resample(_ samples: [Float], from: Double, to: Double) -> [Float] {
    guard !samples.isEmpty, from > 0, to > 0 else { return samples }
    let count = Int((Double(samples.count) * to / from).rounded())
    let step = from / to
    let last = samples.count - 1
    return (0..<count).map { index in
      let position = Double(index) * step
      let before = min(last, Int(position))
      let after = min(last, before + 1)
      let fraction = Float(position - Double(before))
      return samples[before] + (samples[after] - samples[before]) * fraction
    }
  }

  // MARK: Reading

  /// How one sample is stored.
  private enum Encoding {
    case unsigned8, signed16, signed24, signed32, float32, float64
  }

  /// What the `fmt ` chunk says.
  private struct Format {
    var encoding: Encoding
    var channels: Int
    var sampleRate: Double
    /// Bytes from one frame to the next, every channel's sample in it.
    var blockAlign: Int
    /// Bytes in one sample.
    var width: Int

    /// The tail every extensible subformat GUID shares; its first two bytes are the plain format tag.
    private static let guidTail: [UInt8] = [0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71]

    init(_ bytes: Bytes, _ chunk: Range<Int>) throws {
      let at = chunk.lowerBound
      guard chunk.count >= 16 else { throw WAVDecodingError.missingFormat }
      var tag = Int(bytes.uint16(at: at))
      let bits = Int(bytes.uint16(at: at + 14))
      channels = Int(bytes.uint16(at: at + 2))
      sampleRate = Double(bytes.uint32(at: at + 4))
      blockAlign = Int(bytes.uint16(at: at + 12))
      // WAVE_FORMAT_EXTENSIBLE: the real tag is in the subformat, after the valid bits and the
      // speaker mask. The bits above are the container's, which is what the data is laid out in.
      if tag == 0xFFFE {
        guard chunk.count >= 40 else {
          throw WAVDecodingError.malformed("its extensible format is too short to name a subformat")
        }
        guard bytes.raw[at + 26..<at + 40].elementsEqual(Self.guidTail) else {
          throw WAVDecodingError.unsupported(formatTag: tag, bitsPerSample: bits)
        }
        tag = Int(bytes.uint16(at: at + 24))
      }
      switch (tag, bits) {
      case (1, 8): encoding = .unsigned8
      case (1, 16): encoding = .signed16
      case (1, 24): encoding = .signed24
      case (1, 32): encoding = .signed32
      case (3, 32): encoding = .float32
      case (3, 64): encoding = .float64
      default: throw WAVDecodingError.unsupported(formatTag: tag, bitsPerSample: bits)
      }
      width = bits / 8
      guard channels > 0 else { throw WAVDecodingError.malformed("it has no channels") }
      guard sampleRate > 0 else { throw WAVDecodingError.malformed("its sample rate is zero") }
      guard blockAlign >= channels * width else {
        throw WAVDecodingError.malformed("its frames are too short for their samples")
      }
    }

    /// One sample, from -1 to 1.
    func sample(_ bytes: Bytes, at: Int) -> Float {
      switch encoding {
      // Eight-bit samples alone are unsigned, silent at 128.
      case .unsigned8: return (Float(bytes.raw[at]) - 128) / 128
      case .signed16: return Float(Int16(bitPattern: bytes.uint16(at: at))) / 32768
      case .signed24:
        // Three bytes put at the top of a 32-bit word and shifted back down, which carries the sign.
        let word =
          UInt32(bytes.raw[at]) << 8 | UInt32(bytes.raw[at + 1]) << 16 | UInt32(bytes.raw[at + 2]) << 24
        return Float(Int32(bitPattern: word) >> 8) / 8_388_608
      case .signed32: return Float(Int32(bitPattern: bytes.uint32(at: at))) / 2_147_483_648
      case .float32: return Float(bitPattern: bytes.uint32(at: at))
      case .float64: return Float(Double(bitPattern: bytes.uint64(at: at)))
      }
    }
  }

  /// A file's bytes, read little-endian as RIFF is written.
  private struct Bytes {
    let raw: UnsafeRawBufferPointer
    var count: Int { raw.count }

    func uint16(at: Int) -> UInt16 {
      UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt16.self))
    }
    func uint32(at: Int) -> UInt32 {
      UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))
    }
    func uint64(at: Int) -> UInt64 {
      UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt64.self))
    }
    /// A chunk's four-letter id.
    func id(at: Int) -> String { String(decoding: raw[at..<at + 4], as: UTF8.self) }
  }

  /// The file's rate, and its audio at that rate.
  private static func read(_ bytes: Bytes) throws -> (rate: Double, channels: [[Float]]) {
    guard bytes.count >= 12, bytes.id(at: 0) == "RIFF", bytes.id(at: 8) == "WAVE" else {
      throw WAVDecodingError.notWAV
    }
    // After the header, chunks one after another to the end: an id, a size, the body, and a pad
    // byte after a body of odd length. Only the format and the audio matter; the rest — lists,
    // cues, broadcast metadata — are stepped over.
    var format: Format?
    var audio: Range<Int>?
    var at = 12
    while at + 8 <= bytes.count {
      let size = Int(clamping: bytes.uint32(at: at + 4))
      let body = at + 8
      let available = bytes.count - body
      // A recorder that stopped before finishing its file can leave a size longer than what is
      // there: take what is there, and that is the last chunk.
      let chunk = body..<body + min(size, available)
      switch bytes.id(at: at) {
      case "fmt ": format = try Format(bytes, chunk)
      case "data" where audio == nil: audio = chunk
      default: break
      }
      if size >= available { break }
      at = body + size + size % 2
    }
    guard let format else { throw WAVDecodingError.missingFormat }
    guard let audio else { throw WAVDecodingError.missingData }
    let frames = audio.count / format.blockAlign
    let channels = (0..<format.channels).map { channel in
      (0..<frames).map { frame in
        format.sample(bytes, at: audio.lowerBound + frame * format.blockAlign + channel * format.width)
      }
    }
    return (format.sampleRate, channels)
  }
}

/// The breaks a patch can be built around, made from the 909 rather than shipped: the reference's
/// `breaks.ts`, rendered by the native engine as the reference renders them — each voice alone
/// through the master, summed, the second of two bars kept so the first bar's tails are in it.
public struct RackBreak: Sendable {
  public let id: String
  public let name: String
  public let tempo: Double
  public let tracks: [String: String]

  public static let all: [RackBreak] = [
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

  public static func named(_ id: String) -> RackBreak? { all.first { $0.id == id } }

  /// Frames in a bar of 4/4 at `tempo`.
  public static func barFrames(_ tempo: Double, _ sampleRate: Double) -> Int {
    Int(RackDisplay.jsRound(sampleRate * 60 * 4 / tempo))
  }

  /// `X` an accent, `x` a hit, anything else a rest; spaces are for reading.
  public static func steps(_ line: String) -> [StepValue] {
    line.filter { !$0.isWhitespace }.map { $0 == "X" ? .accent : $0 == "x" ? .on : .off }
  }

  public var song: Song {
    var pattern = DriftboxSeq.Pattern(id: "break", name: name, length: 16)
    for (voice, line) in tracks { pattern.tracks[voice] = Self.steps(line) }
    var song = Song(bpm: tempo, patterns: [pattern])
    song.swing = 0
    song.chain = [ChainStep(pattern: "break", repeat: 2)]
    return song
  }

  /// One bar of the break at `sampleRate`, mono, its loudest sample 0.9.
  public func render(sampleRate: Double) -> [Float] {
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
