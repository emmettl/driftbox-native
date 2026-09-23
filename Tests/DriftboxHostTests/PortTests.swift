import ConformanceSupport
import DriftboxDocument
import DriftboxEngine
import DriftboxHost
import DriftboxSeq
import Testing

/// The platform-neutral half of the host: what every platform's adapter is built on, tested
/// wherever the package builds.
struct PortTests {
  @Test func theChosenDeviceIsPlayedThroughOnlyWhileItIsThere() {
    let speakers = AudioDevice(id: "speakers", name: "Speakers")
    let interface = AudioDevice(id: "interface", name: "Interface")
    let both = [speakers, interface]
    #expect(AudioDevices.pick(chosen: "interface", among: both, systemDefault: speakers) == interface)
    #expect(AudioDevices.pick(chosen: "interface", among: [speakers], systemDefault: speakers) == speakers)
    #expect(AudioDevices.pick(chosen: nil, among: both, systemDefault: speakers) == speakers)
    #expect(AudioDevices.pick(chosen: nil, among: [], systemDefault: nil) == nil)
  }

  @Test func hostTimeRoundTrips() {
    let now = HostTime.now()
    for seconds in [0.0, 0.001, 0.25, -0.1, 3.5] {
      let later = HostTime.time(now, after: seconds)
      #expect(abs(HostTime.seconds(from: now, to: later) - seconds) < 1e-6)
    }
    #expect(HostTime.time(now, after: .nan) == now)
    #expect(HostTime.time(10, after: -1e9) == 0)
  }

  @Test func hostTimeMoves() {
    let before = HostTime.now()
    var spin = 0.0
    for index in 0..<200_000 { spin += Double(index) }
    #expect(spin > 0)
    #expect(HostTime.now() > before)
  }

  @Test func midiBytesMeanNotesAndClock() {
    #expect(MIDIMessage(status: 0x90, 60, 127) == .note(60, velocity: 1))
    #expect(MIDIMessage(status: 0x93, 36, 0) == .note(36, velocity: 0))
    #expect(MIDIMessage(status: 0x80, 60, 64) == .note(60, velocity: 0))
    #expect(MIDIMessage(status: 0xF8, 0, 0) == .clock(.tick))
    #expect(MIDIMessage(status: 0xFA, 0, 0) == .clock(.start))
    #expect(MIDIMessage(status: 0xB0, 7, 100) == nil)
  }

  /// A source is the host's own render, called through a C function and a pointer: what a
  /// device's thread does with it must be what calling the host directly does.
  @Test func aRenderSourceRendersItsHost() throws {
    let song = try #require(SongCodec.decode(try Fixtures.text("documents/acid.song.json")))
    func render(_ body: (EngineHost, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Void)
      -> [Float]
    {
      let host = EngineHost(sampleRate: 48000)
      host.load(song)
      host.send(.play)
      var left = [Float](repeating: 0, count: 4800)
      var right = left
      left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in body(host, l.baseAddress!, r.baseAddress!) }
      }
      return left + right
    }
    let direct = render { host, l, r in
      for block in 0..<10 { host.render(frames: 480, left: l + block * 480, right: r + block * 480) }
    }
    let throughSource = render { host, l, r in
      let source = host.renderSource
      #expect(source.sampleRate == 48000)
      for block in 0..<10 { source.render(source.context, 480, l + block * 480, r + block * 480) }
    }
    #expect(direct == throughSource)
    #expect(direct.contains { $0 != 0 })
  }
}
