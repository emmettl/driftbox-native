#if os(Linux)
  import CPipeWireBridge
  import DriftboxDocument
  import DriftboxEngine
  import DriftboxHost
  import DriftboxHostLinux
  import Foundation
  import Glibc

  @MainActor
  func runLinuxPlayer(_ arguments: [String]) throws {
    if arguments == ["--gpu-info"] {
      try reportLinuxGPU()
      return
    }
    var arguments = arguments
    func option(_ flag: String) throws -> Double? {
      guard let index = arguments.firstIndex(of: flag) else { return nil }
      guard index + 1 < arguments.count, let value = Double(arguments[index + 1]),
        value.isFinite, value >= 0
      else { throw PipeWireError("\(flag) needs a finite nonnegative number") }
      arguments.removeSubrange(index...index + 1)
      return value
    }
    let seconds = try option("--seconds")
    let startBar = try option("--start-bar") ?? 0
    guard startBar <= 1_000_000 else { throw PipeWireError("--start-bar is too large") }
    let bench = arguments.firstIndex(of: "--bench").map { arguments.remove(at: $0) } != nil
    guard arguments.count == 1, !arguments[0].hasPrefix("--") else {
      throw PipeWireError(
        "usage: driftbox-play <song.json> [--seconds s] [--start-bar n] [--bench], or --gpu-info")
    }
    let text = String(decoding: try Data(contentsOf: URL(fileURLWithPath: arguments[0])), as: UTF8.self)
    guard let song = SongCodec.decode(text) else { throw PipeWireError("\(arguments[0]) is not a song") }
    if bench {
      runBench(song, named: arguments[0])
      return
    }
    guard db_linux_interrupt_begin() == 0 else { throw PipeWireError("could not install stop handlers") }
    defer { db_linux_interrupt_end() }
    let output = try PipeWireOutput()
    defer { output.stop() }
    let host = EngineHost(sampleRate: output.sampleRate)
    host.load(song)
    if startBar > 0, let last = song.plan(bars: Int(startBar)).last {
      host.send(.seek(songFrame: Int((last.time + last.stepSeconds) * output.sampleRate)))
    }
    host.send(.play)
    try output.attach(host.renderSource)
    defer { output.detach(host.renderSource.context) }
    print("playing \(arguments[0]) through PipeWire's default output at \(Int(output.sampleRate)) Hz")
    print("ctrl-c to stop")
    let began = HostTime.now()
    var reported = began
    var progressed = began
    var frames: UInt64 = 0
    while db_linux_interrupted() == 0 {
      let now = HostTime.now()
      if let seconds, HostTime.seconds(from: began, to: now) >= seconds { break }
      _ = try output.isStreaming()
      let current = output.renderedFrames
      if current != frames {
        frames = current
        progressed = now
      }
      guard HostTime.seconds(from: progressed, to: now) < 3 else {
        throw PipeWireError("PipeWire stopped requesting audio for 3 seconds")
      }
      if HostTime.seconds(from: reported, to: now) >= 1 {
        let load = host.takeLoad()
        let peak = max(
          Float(bitPattern: host.peakLeft.load(ordering: .relaxed)),
          Float(bitPattern: host.peakRight.load(ordering: .relaxed)))
        print("  \(frames) frames, peak \(fixed(Double(peak), 3)), render \(fixed(load.fraction * 100, 1))%")
        reported = now
      }
      usleep(10_000)
    }
    output.detach(host.renderSource.context)
    output.stop()
    print("stopped cleanly after \(output.renderedFrames) rendered frames")
  }
#endif
