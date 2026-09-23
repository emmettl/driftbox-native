#if canImport(AVFoundation)
  import ConformanceSupport
  import DriftboxDocument
  import DriftboxEngine
  import DriftboxHost
  import DriftboxRack
  import DriftboxSeq
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// A groovebox song in the rack, from the app's side: opening one, editing it in the groovebox
  /// window with its edits coming straight back, starting it at a bar and looping it, and what
  /// the rack says about the document.
  @MainActor
  struct RackGrooveboxAppTests {
    static func song() throws -> Song {
      try #require(SongCodec.decode(try Fixtures.text("documents/garage.song.json")))
    }

    /// A rack and a groovebox window beside it, neither with a device.
    static func pair() -> (RackModel, Player) {
      let rack = RackModel()
      let player = Player(host: EngineHost(sampleRate: 48000))
      rack.groovebox = player
      return (rack, player)
    }

    @Test func aSongOpensWholeWithItsSource() throws {
      let (rack, _) = Self.pair()
      let song = try Self.song()
      rack.openSong(song, name: "Garage")
      #expect(rack.name == "Garage")
      #expect(rack.patch.modules.map(\.type) == ["groovebox"])
      #expect(rack.song == song)
      #expect(rack.compatibility == .grooveboxCompatible)
      #expect(rack.notice?.label == "groovebox compatible")

      rack.add("vco")
      #expect(rack.compatibility == .rackExtended)
      #expect(rack.notice?.guidance.contains("keeps the rack's additions") == true)
      #expect(rack.song == song, "and the song is still the song")
    }

    /// Edited in the groovebox window, the rack's song changes in place; undoing in the rack
    /// leaves the song alone, whose history is the window's.
    @Test func theGrooveboxWindowEditsTheRacksSong() throws {
      let (rack, player) = Self.pair()
      let song = try Self.song()
      rack.openSong(song, name: "Garage")
      rack.editInGroovebox()
      #expect(rack.songLinked)
      #expect(player.linkedToRack)
      #expect(player.song == song)
      #expect(player.documentName == "Garage")

      rack.add("vco")
      player.edit("Set Tempo") { $0.bpm = 97 }
      #expect(rack.song?.bpm == 97)
      #expect(rack.tempo == 97)
      rack.undo()
      #expect(rack.patch.modules.map(\.type) == ["groovebox"], "the rack's own edit undone")
      #expect(rack.song?.bpm == 97, "and the song as the window left it")

      // Something else opened in the window ends the link, and the rack's song stays as it was.
      player.open(try #require(player.entries.first { $0.name != "Garage" }))
      #expect(!rack.songLinked)
      #expect(!player.linkedToRack)
      player.edit("Set Tempo") { $0.bpm = 150 }
      #expect(rack.song?.bpm == 97)
    }

    @Test func anotherPatchInTheRackEndsTheLink() throws {
      let (rack, player) = Self.pair()
      rack.openSong(try Self.song(), name: "Garage")
      rack.editInGroovebox()
      rack.open(Patch(modules: [], cables: []), name: "Empty")
      #expect(!rack.songLinked)
      #expect(!player.linkedToRack)
      #expect(rack.song == nil)
      #expect(rack.notice == nil)
    }

    /// A start at a bar sets the rack running and puts the song at that bar's first frame; a loop
    /// fits inside the song, as the reference's `clampBar` and `clampLoop` keep it.
    @Test func theSongStartsAtABarAndLoops() throws {
      let (rack, _) = Self.pair()
      let song = try Self.song()
      rack.openSong(song, name: "Garage")
      // A loop asked for before the rack is listening is kept, and sent when it is.
      rack.loopSong(start: 1, bars: 2)
      #expect(rack.songLoop?.start == 1 && rack.songLoop?.bars == 2)
      rack.clearSongLoop()
      rack.listen()
      #expect(!rack.running)
      rack.startSong(atBar: 2)
      #expect(rack.running)
      let left = UnsafeMutablePointer<Float>.allocate(capacity: 128)
      let right = UnsafeMutablePointer<Float>.allocate(capacity: 128)
      defer {
        left.deallocate()
        right.deallocate()
      }
      rack.host.render(frames: 128, left: left, right: right)
      let expected = Int((Timeline(song: song).start(ofBar: 2) * 48000).rounded()) + 128
      let frame = rack.host.song.songFrame.load(ordering: .relaxed)
      #expect(frame == expected)

      rack.loopSong(start: song.bars - 1, bars: 4)
      #expect(rack.songLoop?.start == song.bars - 1)
      #expect(rack.songLoop?.bars == 1, "no further than the song goes")
      rack.clearSongLoop()
      #expect(rack.songLoop == nil)

      #expect(RackModel.clampBar(-3, 8) == 0)
      #expect(RackModel.clampBar(12, 8) == 7)
      #expect(RackModel.clampLoop(6, 4, 8) == (6, 2))
      #expect(RackModel.clampLoop(0, 0, 8) == (0, 1))
    }

    @Test func theNoticeSaysWhatTheReferencesSays() {
      #expect(DocumentNotice.notice(.rackNative, song: (3, 120)) == nil)
      let compatible = DocumentNotice.notice(.grooveboxCompatible, song: (3, 122.5))
      #expect(compatible?.retained == "3 patterns at 122.5 BPM retained exactly.")
      #expect(compatible?.guidance.contains("loses nothing") == true)
      let unreadable = DocumentNotice.notice(.rackExtended, song: nil)
      #expect(unreadable?.label == "rack extended")
      #expect(unreadable?.retained.contains("newer groovebox build") == true)
    }
  }
#endif
