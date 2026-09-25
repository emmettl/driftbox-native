#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxDocument
  import DriftboxHostMac
  import DriftboxSeq
  import DriftboxSession
  import Foundation
  import SwiftUI
  import Synchronization
  import Testing

  @testable import DriftboxExtensions

  /// The groovebox's Audio Unit as another app sees it, with its owner behind it: made at the app's
  /// rate, its presets the catalogue's songs and its state the song, played by the app's MIDI, and
  /// keeping the app's time. Made in-process here, as the extension makes it out of process.
  @MainActor
  struct GrooveboxPluginTests {
    static func unit(rate: Double = 44100) throws -> (GrooveboxAudioUnit, GrooveboxPlugin) {
      let unit = try GrooveboxAudioUnit(componentDescription: GrooveboxAudioUnit.componentDescription)
      GrooveboxPlugin.attach(to: unit)
      let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
      try unit.outputBusses[0].setFormat(format)
      return (unit, try #require(unit.owner as? GrooveboxPlugin))
    }

    /// As many of the owner's ticks as reach the session's own.
    static func tickSession(_ plugin: GrooveboxPlugin) {
      for _ in 0..<Plugins.sessionEvery { plugin.tick() }
    }

    @Test func aSessionIsMadeAtTheAppsRate() throws {
      let (unit, plugin) = try Self.unit(rate: 44100)
      #expect(plugin.session == nil, "nothing until the app readies the unit")
      try unit.allocateRenderResources()
      let session = try #require(plugin.session)
      #expect(session.sampleRate == 44100)
      #expect(unit.host === session.host)
      #expect(session.documentName == Catalogue.entries().first?.name)
      #expect(!session.isPlaying, "opened stopped: the app says when to play")

      // Another rate makes the session again, keeping the song it had.
      unit.currentPreset = unit.factoryPresets?[2]
      let chosen = session.song
      unit.deallocateRenderResources()
      try unit.outputBusses[0].setFormat(
        try #require(AVAudioFormat(standardFormatWithSampleRate: 96000, channels: 2)))
      try unit.allocateRenderResources()
      let again = try #require(plugin.session)
      #expect(again !== session)
      #expect(again.sampleRate == 96000)
      #expect(again.song == chosen)
      #expect(again.documentName == Catalogue.entries()[2].name)
    }

    /// The catalogue's songs are the presets; the state is the song, kept as it is edited, and a
    /// state restored before the session exists is opened when it does.
    @Test func thePresetsAreTheSongsAndTheStateIsTheSong() throws {
      let (unit, plugin) = try Self.unit()
      #expect(unit.factoryPresets?.map(\.name) == Catalogue.entries().map(\.name))
      try unit.allocateRenderResources()
      unit.currentPreset = unit.factoryPresets?[3]
      let session = try #require(plugin.session)
      #expect(session.documentName == Catalogue.entries()[3].name)
      #expect(!session.isPlaying)

      // An edit is what the app saves, once the owner has seen it.
      session.edit { $0.bpm = 101 }
      Self.tickSession(plugin)
      let state = try #require(unit.fullState)
      let document = try #require(state["song"] as? String)
      let saved = try #require(SongCodec.decode(document))
      #expect(saved.bpm == 101)

      let (other, otherPlugin) = try Self.unit()
      other.fullState = state
      try other.allocateRenderResources()
      #expect(otherPlugin.session?.song == session.song)
      #expect(otherPlugin.session?.documentName == Catalogue.entries()[3].name)
    }

    /// A note from the app strikes a drum, as a keyboard plugged into the Mac does: note 21 is the
    /// first of them.
    @Test func theAppsMIDIPlaysTheGroovebox() throws {
      let (unit, plugin) = try Self.unit()
      try unit.allocateRenderResources()
      #expect(RackPluginTests.render(unit, frames: 4410).allSatisfy { abs($0) < 1e-4 }, "silent, stopped")

      let schedule = try #require(unit.scheduleMIDIEventBlock)
      let note: [UInt8] = [0x90, 21, 127]
      schedule(AUEventSampleTimeImmediate, 0, 3, note)
      _ = RackPluginTests.render(unit, frames: 512)
      plugin.tick()
      let struck = RackPluginTests.render(unit, frames: 4410)
      #expect(struck.contains { abs($0) > 0.01 }, "heard once the key is down")
    }

    /// The groovebox runs at the app's tempo, and starts and stops as the app's transport does —
    /// as changes, so its own Play still plays while the app stands still.
    @Test func theGrooveboxKeepsTheAppsTime() throws {
      let (unit, plugin) = try Self.unit()
      let moving = Mutex(false)
      unit.musicalContextBlock = { tempo, _, _, _, _, _ in
        tempo?.pointee = 97
        return true
      }
      unit.transportStateBlock = { flags, _, _, _ in
        flags?.pointee = moving.withLock { $0 } ? .moving : []
        return true
      }
      try unit.allocateRenderResources()
      let session = try #require(plugin.session)
      let songBPM = try #require(session.song?.bpm)
      _ = RackPluginTests.render(unit, frames: 512)
      Self.tickSession(plugin)
      #expect(session.tempo == 97)
      #expect(session.song?.bpm == songBPM, "followed, not written into the song")
      #expect(!session.isPlaying)

      moving.withLock { $0 = true }
      _ = RackPluginTests.render(unit, frames: 512)
      Self.tickSession(plugin)
      _ = RackPluginTests.render(unit, frames: 512)
      Self.tickSession(plugin)
      #expect(session.isPlaying)

      moving.withLock { $0 = false }
      _ = RackPluginTests.render(unit, frames: 512)
      Self.tickSession(plugin)
      _ = RackPluginTests.render(unit, frames: 512)
      Self.tickSession(plugin)
      #expect(!session.isPlaying)

      // Played from the face while the app stands still: it plays on.
      session.play()
      for _ in 0..<4 {
        _ = RackPluginTests.render(unit, frames: 512)
        Self.tickSession(plugin)
      }
      #expect(session.isPlaying)
    }

    /// The face is the groovebox's editor, on the session the unit plays; and it draws.
    @Test func theFaceIsTheGrooveboxsOwn() throws {
      let (unit, plugin) = try Self.unit()
      let waiting = try RackPluginTests.colours(GrooveboxPluginView(plugin: plugin))
      try unit.allocateRenderResources()
      #expect(plugin.session != nil && plugin.stage != nil)
      #expect(try RackPluginTests.colours(GrooveboxPluginView(plugin: plugin)) > 4 * waiting)
    }
  }
#endif
