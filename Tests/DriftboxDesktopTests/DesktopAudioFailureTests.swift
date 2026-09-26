import DriftboxDocument
import DriftboxHost
import DriftboxRackSession
import DriftboxSeq
import DriftboxSession
import DriftboxText
import Foundation
import Testing

@testable import DriftboxDesktop
@testable import DriftboxEngine

@MainActor
struct DesktopAudioFailureTests {
  static func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func aFailedMixCanBeRetriedWithoutChangingTheSong() async throws {
    let device = try #require(try DesktopTests.devices().first)
    let (desktop, window, _) = try DesktopTests.desktop(on: device)
    desktop.session.open(DesktopTests.song(), named: "Kept")
    let song = desktop.session.song
    let directory = try Self.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    window.saveLocation = directory.appendingPathComponent("missing/Mix.wav")
    window.choose(DesktopMenus.exportMix)
    await desktop.exporting?.value
    #expect(window.told.count == 1 && window.told[0].hasPrefix("Could not export Mix.wav:"))
    #expect(!desktop.documentRequestPending && desktop.session.song == song)
    window.saveLocation = nil
    window.choose(DesktopMenus.exportMix)
    #expect(window.told.count == 1, "cancelling is not a failed export")
    let saved = directory.appendingPathComponent("Mix.wav")
    window.saveLocation = saved
    window.choose(DesktopMenus.exportMix)
    await desktop.exporting?.value
    #expect(try Data(contentsOf: saved).prefix(4) == Data("RIFF".utf8))
    #expect(window.told.count == 1 && desktop.session.song == song)
  }

  @Test func aPartialStemExportStopsAndExplainsWhatWasWritten() async throws {
    let device = try #require(try DesktopTests.devices().first)
    let (desktop, window, _) = try DesktopTests.desktop(on: device)
    var song = DesktopTests.song()
    song.patterns[0].tracks["909.sd"] = [.on]
    song.patterns[0].tracks["909.ch"] = [.on]
    desktop.session.open(song, named: "Stems")
    let voices = SongRenderer.voicesUsed(song)
    try #require(voices.count == 3)
    let directory = try Self.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // A directory at the second file's path makes that write fail on every platform.
    let blocked = directory.appendingPathComponent("Stems - \(voices[1]).wav")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
    let marker = blocked.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: marker)
    window.folder = directory
    window.choose(DesktopMenus.exportStems)
    await desktop.exporting?.value
    #expect(window.told.count == 1)
    #expect(window.told[0].contains(blocked.lastPathComponent))
    #expect(window.told[0].contains("1 stem was already exported"))
    let first = directory.appendingPathComponent("Stems - \(voices[0]).wav")
    #expect(try Data(contentsOf: first).prefix(4) == Data("RIFF".utf8))
    #expect(try Data(contentsOf: marker) == Data("keep".utf8))
    #expect(
      !FileManager.default.fileExists(
        atPath:
          directory.appendingPathComponent("Stems - \(voices[2]).wav").path))
    #expect(desktop.session.song == song)
  }

  @Test func failedImportsNotifyWithoutReplacingTheExistingAudio() async throws {
    let device = try #require(try DesktopTests.devices().first)
    let window = StandInWindow()
    let rack = RackSession()
    let desktop = try Desktop(
      session: Session(host: EngineHost(sampleRate: 48000)), window: window, device: device,
      surface: StandInSurface(device: device, width: 320, height: 180),
      typesetter: NoTypesetter(), rack: rack)
    await rack.breaksReady()
    let sampler = try #require(rack.add("sampler"))
    let track = try #require(rack.add("audio-track"))
    let instrument = try #require(rack.add("multisampler"))
    let directory = try Self.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let good = directory.appendingPathComponent("Good_C3.wav")
    let bad = directory.appendingPathComponent("Broken_C4.wav")
    let samples = [Float](repeating: 0.2, count: 48000)
    try WAV.data(.init(left: samples, right: samples), sampleRate: 48000).write(to: good)
    try Data("not audio".utf8).write(to: bad)
    await rack.load(good, into: sampler)
    await rack.loadTrack(good, into: track)
    await rack.loadInstrument([good], into: instrument)
    let sample = rack.samples[sampler]
    let recording = rack.tracks[track]
    let recordings = rack.recordings[instrument]
    let patch = rack.patch
    #expect(window.told.isEmpty)
    await rack.load(bad, into: sampler)
    await rack.loadTrack(bad, into: track)
    await rack.loadInstrument([good, bad], into: instrument)
    #expect(window.told.count == 3)
    #expect(window.told.allSatisfy { $0 == "Could not load Broken_C4.wav: Not a WAV file." })
    #expect(rack.loadFailure?.module == instrument, "the module face keeps its failure")
    #expect(rack.samples[sampler] == sample && rack.tracks[track] == recording)
    #expect(rack.recordings[instrument] == recordings && rack.patch == patch)
    #expect(rack.loading.isEmpty && !desktop.showsRack, "off-screen modules still report failures")
    desktop.refresh()
    #expect(window.told.count == 3, "refresh does not repeat a failure")
    async let first: Void = rack.load(bad, into: sampler)
    async let second: Void = rack.loadTrack(bad, into: track)
    _ = await (first, second)
    #expect(window.told.count == 5, "each concurrent retry reports its own failure")
  }
}
