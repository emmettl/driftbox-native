import ConformanceSupport
import DriftboxDocument
import DriftboxEngine
import DriftboxSeq
import Testing

struct EventRingTests {
  /// Every hit and note the plan says the song plays, the engine reports, on its frame.
  @Test func theEngineReportsWhatItPlays() throws {
    let song = try #require(SongCodec.decode(try Fixtures.text("documents/acid.song.json")))
    let sampleRate = 48000.0
    var engine = SongEngine(sampleRate: sampleRate)
    let compiled = UnsafeMutablePointer<CompiledSong>.allocate(capacity: 1)
    compiled.initialize(to: CompiledSong(song, preparer: engine.voices.preparer))
    engine.load(compiled)
    engine.play()
    let frames = 4 * 48000
    var left = [Float](repeating: 0, count: 512)
    var right = [Float](repeating: 0, count: 512)
    var done = 0
    while done < frames {
      left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
          engine.render(frames: 512, left: l.baseAddress!, right: r.baseAddress!)
        }
      }
      done += 512
    }
    var hits: [(Int, Int)] = []
    var notes: [(Int, Float)] = []
    while let event = engine.events.receive() {
      switch event.kind {
      case .hit: hits.append((event.frame, event.voice))
      case .note: notes.append((event.frame, event.frequency))
      case .pass: break
      }
    }
    engine.load(nil)
    compiled.deinitialize(count: 1)
    compiled.deallocate()

    let plan = song.plan(bars: song.bars)
    let expectedHits = plan.flatMap { $0.drums }.filter { $0.time < 4 }.map { hit in
      (
        Int((hit.time * sampleRate).rounded(.down)),
        allVoices.firstIndex { voice in voice.id == hit.voiceId }!
      )
    }
    var expectedNotes: [(Int, Float)] = []
    for hit in plan.flatMap({ $0.bass }) where hit.time < 4 {
      let frame = Int((hit.time * sampleRate).rounded(.up))
      expectedNotes.append((frame, Float(hit.note.frequency)))
    }
    #expect(hits.count == expectedHits.count)
    var hitsMatch = true
    for (mine, theirs) in zip(hits, expectedHits) where mine.0 != theirs.0 || mine.1 != theirs.1 {
      hitsMatch = false
    }
    #expect(hitsMatch)
    #expect(notes.count == expectedNotes.count)
    var notesMatch = true
    for (mine, theirs) in zip(notes, expectedNotes) where mine.0 != theirs.0 || mine.1 != theirs.1 {
      notesMatch = false
    }
    #expect(notesMatch)
    #expect(hits.count > 8 && notes.count >= 1, "\(hits.count) hits, \(notes.count) notes")
  }

  @Test func aFullRingKeepsTheNewest() {
    var ring = EventRing()
    for index in 0..<(EventRing.capacity + 10) {
      ring.send(EngineEvent(kind: .hit, frame: index, voice: 0, level: 1, frequency: 0, flag: 0))
    }
    let first = ring.receive()
    #expect(first?.frame == 10)
    var count = 1
    while ring.receive() != nil { count += 1 }
    #expect(count == EventRing.capacity)
  }
}
