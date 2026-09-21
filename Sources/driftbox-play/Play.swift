#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxDocument
  import DriftboxEngine
  import DriftboxHost
  import Foundation

  /// Somewhere for an instantiation callback to leave what it made.
  final class Made: @unchecked Sendable {
    var unit: AVAudioUnit?
  }

  /// Plays a song through the speakers: the engine as an Audio Unit, hosted in an AVAudioEngine.
  ///
  ///     swift run -c release driftbox-play conformance/fixtures/documents/acid.song.json
  ///     swift run -c release driftbox-play song.json --seconds 20 --start-bar 8
  /// The loudest sample seen since last asked, from the audio thread's tap.
  final class Peak: @unchecked Sendable {
    private var value: Float = 0
    private let lock = NSLock()
    func note(_ sample: Float) {
      lock.withLock { value = max(value, sample) }
    }
    func take() -> Float {
      lock.withLock {
        defer { value = 0 }
        return value
      }
    }
  }

  @main
  struct Play {
    static func main() throws {
      var arguments = Array(CommandLine.arguments.dropFirst())
      func option(_ name: String) -> Double? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        defer { arguments.removeSubrange(index...index + 1) }
        return Double(arguments[index + 1])
      }
      let seconds = option("--seconds")
      let startBar = option("--start-bar") ?? 0
      guard arguments.count == 1 else {
        FileHandle.standardError.write(
          Data("usage: driftbox-play <song.json> [--seconds s] [--start-bar n]\n".utf8))
        exit(64)
      }
      let text = String(decoding: try Data(contentsOf: URL(fileURLWithPath: arguments[0])), as: UTF8.self)
      guard let song = SongCodec.decode(text) else {
        FileHandle.standardError.write(Data("\(arguments[0]) is not a song\n".utf8))
        exit(65)
      }

      AUAudioUnit.registerSubclass(
        DriftboxAudioUnit.self, as: DriftboxAudioUnit.componentDescription, name: "Driftbox", version: 1)
      let audio = AVAudioEngine()
      let made = Made()
      let group = DispatchGroup()
      group.enter()
      AVAudioUnit.instantiate(with: DriftboxAudioUnit.componentDescription, options: []) { unit, error in
        if let error { FileHandle.standardError.write(Data("\(error)\n".utf8)) }
        made.unit = unit
        group.leave()
      }
      group.wait()
      guard let unit = made.unit, let driftbox = unit.auAudioUnit as? DriftboxAudioUnit else { exit(70) }

      audio.attach(unit)
      audio.connect(unit, to: audio.mainMixerNode, format: unit.outputFormat(forBus: 0))
      driftbox.load(song)
      if startBar > 0 {
        let plan = song.plan(bars: Int(startBar))
        if let last = plan.last {
          driftbox.send(
            .seek(songFrame: Int((last.time + last.stepSeconds) * unit.outputFormat(forBus: 0).sampleRate)))
        }
      }
      driftbox.send(.play)

      // What reaches the output, once a second: proof of life for a run nobody is listening to.
      let peak = Peak()
      // Called on an audio queue, so it must not inherit `main`'s actor.
      let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
        guard let data = buffer.floatChannelData else { return }
        var loudest: Float = 0
        for frame in 0..<Int(buffer.frameLength) {
          loudest = max(loudest, abs(data[0][frame]), abs(data[1][frame]))
        }
        peak.note(loudest)
      }
      audio.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil, block: tap)
      try audio.start()

      let length = SongRenderer.seconds(of: song)
      print(
        String(
          format: "playing %@ (%.0f seconds a pass) at %.0f Hz", arguments[0], length,
          unit.outputFormat(forBus: 0).sampleRate))
      let until = seconds.map { Date().addingTimeInterval($0) }
      if until == nil { print("ctrl-c to stop") }
      while until.map({ Date() < $0 }) ?? true {
        Thread.sleep(forTimeInterval: 1)
        print(
          String(
            format: "  peak %.3f  song frame %d", peak.take(),
            driftbox.host?.songFrame.load(ordering: .relaxed) ?? -1))
      }
      audio.stop()
    }
  }
#else
  @main
  struct Play {
    static func main() { print("driftbox-play needs AVFoundation") }
  }
#endif
