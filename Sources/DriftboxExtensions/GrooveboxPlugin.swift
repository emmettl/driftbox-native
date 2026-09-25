#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxApp
  import DriftboxDocument
  import DriftboxHost
  import DriftboxHostMac
  import DriftboxSeq
  import DriftboxSession
  import Foundation
  import Observation

  /// The groovebox inside another app: the `Session` every platform shares, behind the groovebox's
  /// Audio Unit, as `RackPlugin` has the rack.
  ///
  /// - The session is made at the rate the app asks for when it readies the unit, and made again if
  ///   it asks for another, keeping the song; until then there is nothing to play.
  /// - Its face is the groovebox's editor, on the same session, with the visuals behind it.
  /// - The app's presets are the catalogue's songs, opened stopped; its saved state is the song, as
  ///   a document, kept as it is edited, and restoring one opens it.
  /// - The app's MIDI plays the groovebox as a keyboard plugged into the Mac does — the drums from
  ///   note 21, the 303 from 33 — and it runs at the app's tempo, starting and stopping with its
  ///   transport.
  /// - Its knobs are the unit's parameters, every one of `GrooveboxKnob.all`, for the app to
  ///   automate: a move of the app's is the song's, heard and kept but no step of undo, and a knob
  ///   turned on the face is shown to the app, which can record it.
  ///
  /// The session has no device, no cables and nothing remembered between launches: the app it is in
  /// has all three.
  @MainActor @Observable
  public final class GrooveboxPlugin {
    @ObservationIgnored private weak var unit: GrooveboxAudioUnit?
    public private(set) var session: Session?
    /// What the face's visuals are drawn by, made with the session.
    public private(set) var stage: Stage?
    @ObservationIgnored private let entries = Catalogue.entries()
    /// A state restored or a preset chosen before there was a session to open it in.
    @ObservationIgnored private var pending: (document: String, name: String?)?
    /// The song as last handed to the unit to save, so it is written again only when it changes.
    @ObservationIgnored private var kept: Song?
    /// The song as the app's parameters last showed it.
    @ObservationIgnored private var shown: Song?
    /// The app's MIDI, as the session hears a port's.
    @ObservationIgnored private let midi = UnitMIDI()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var transport = TransportEdge()
    @ObservationIgnored private var ticks = 0

    init(unit: GrooveboxAudioUnit) {
      self.unit = unit
      unit.presetNames = entries.map(\.name)
    }

    /// Give `unit` a groovebox to play, with everything it hears carried to it.
    nonisolated public static func attach(to unit: GrooveboxAudioUnit) {
      publishKnobs(on: unit)
      let held = Held(unit: unit)
      let plugin = Plugins.onMain { GrooveboxPlugin(unit: held.unit) }
      unit.owner = plugin
      unit.prepare = { [weak plugin] rate in Plugins.onMain { plugin?.prepare(rate) } }
      unit.choosePreset = { [weak plugin] number in Plugins.onMain { plugin?.choose(number) } }
      unit.restore = { [weak plugin] document, name in
        Plugins.onMain { plugin?.restore(document, name: name) }
      }
    }

    /// Every knob as a parameter, grouped as the face groups them, each at its rest until there is
    /// a song to say otherwise.
    nonisolated static func publishKnobs(on unit: GrooveboxAudioUnit) {
      let knobs = GrooveboxKnob.all
      var groups: [AUParameterGroup] = []
      var start = 0
      while start < knobs.count {
        let group = knobs[start].group
        var end = start
        var parameters: [AUParameter] = []
        while end < knobs.count, knobs[end].group == group {
          let knob = knobs[end]
          let parameter = AUParameterTree.createParameter(
            withIdentifier: knob.identifier, name: knob.label, address: AUParameterAddress(end), min: 0,
            max: 1,
            unit: .generic, unitName: nil, flags: [.flag_IsReadable, .flag_IsWritable, .flag_CanRamp],
            valueStrings: nil, dependentParameters: nil)
          parameter.value = Float(knob.rest)
          parameters.append(parameter)
          end += 1
        }
        let identifier = String(group.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        groups.append(
          AUParameterTree.createGroup(withIdentifier: identifier, name: group, children: parameters))
        start = end
      }
      unit.publish(groups, count: knobs.count) { address, value in
        address < knobs.count ? knobs[address].display(Double(value)) : ""
      }
      for (address, knob) in knobs.enumerated() { unit.show(Float(knob.rest), at: address) }
    }

    /// A session at `rate`: the one there is if it is already at it, a new one keeping its song if not.
    func prepare(_ rate: Double) {
      guard let unit else { return }
      if let session, session.sampleRate == rate { return }
      let carried =
        session.flatMap { old in old.song.map { (SongCodec.encode($0), old.documentName as String?) } }
        ?? pending
      session?.close()
      let fresh = Session(host: EngineHost(sampleRate: rate), midiIn: midi)
      if let carried, let song = SongCodec.decode(carried.0) {
        fresh.open(song, named: carried.1 ?? Self.untitled)
      } else if let first = entries.first, let song = Catalogue.song(first.id) {
        fresh.open(song, named: first.name)
      }
      pending = nil
      shown = nil
      session = fresh
      stage = Stage(player: fresh)
      unit.host = fresh.host
      // What the app set before there was a song to set it in is the song's, as a state restored
      // before then is.
      knobs(unit, fresh)
      keep()
      if timer == nil {
        timer = Timer.scheduledTimer(withTimeInterval: Plugins.interval, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.tick() }
        }
      }
    }

    static let untitled = "Driftbox"

    func choose(_ number: Int) {
      guard number >= 0, number < entries.count, let song = Catalogue.song(entries[number].id) else { return }
      open(song, named: entries[number].name)
    }

    func restore(_ document: String, name: String?) {
      guard let song = SongCodec.decode(document) else { return }
      open(song, named: name ?? Self.untitled)
    }

    /// Opened stopped, as a preset or a state should be: the app says when to play.
    private func open(_ song: Song, named name: String) {
      guard let session else {
        pending = (SongCodec.encode(song), name)
        return
      }
      session.open(song, named: name)
      keep()
    }

    /// The song, for the app to save, if it has changed since it was last handed over.
    private func keep() {
      guard let unit, let session, let song = session.song, song != kept else { return }
      kept = song
      unit.saved.withLock { $0 = (SongCodec.encode(song), session.documentName) }
    }

    /// What the app has said since last time: its MIDI played, its tempo and transport followed.
    /// And, as often as the face draws, the session's own tick and the song kept.
    func tick() {
      guard let unit, let session else { return }
      while let bytes = unit.nextMIDI() { midi.hear(bytes) }
      if let tempo = unit.appTempo, abs(tempo - session.tempo) >= 0.05 { session.follow(bpm: tempo) }
      if let playing = transport.change(unit.appPlaying), playing != session.isPlaying {
        if playing { session.play() } else { session.stop() }
      }
      ticks += 1
      if ticks % Plugins.sessionEvery == 0 {
        session.tick()
        knobs(unit, session)
        keep()
      }
    }

    /// The app's moves into the song, then the song's knobs out to the app where they have moved
    /// since it was last shown them: by an edit on the face, a preset, an undo.
    private func knobs(_ unit: GrooveboxAudioUnit, _ session: Session) {
      let knobs = GrooveboxKnob.all
      let moves = unit.movedParameters()
      if !moves.isEmpty {
        session.automate { song in
          // A float's shortest decimal, which is what the app set: 0.9 and not 0.8999999761581421,
          // which is what the float's own bits would write into the song's document.
          for move in moves {
            knobs[move.address].set(Double("\(move.value)") ?? Double(move.value), in: &song)
          }
        }
      }
      guard let song = session.song, song != shown else { return }
      shown = song
      for (address, knob) in knobs.enumerated() { unit.show(Float(knob.value(in: song)), at: address) }
    }

    isolated deinit {
      timer?.invalidate()
      session?.close()
    }
  }

  /// The app's MIDI as a port, which is how a session hears MIDI: fed by the owner, on the main
  /// actor, from what the unit took off the render thread.
  final class UnitMIDI: MIDIInputPort, @unchecked Sendable {
    var onNote: (@Sendable (Int, Double) -> Void)?
    var onMessage: (@Sendable ([UInt8]) -> Void)?
    var onClock: (@Sendable (ClockMessage, Double) -> Void)?
    var onSourcesChange: (@Sendable ([String]) -> Void)?
    /// None to choose among: there is one, the app.
    var sources: [String] { [] }
    var ignoring: Set<String> = []

    /// One message, as a port hands it on: a note with its velocity out of one, and every channel
    /// message for whatever else listens.
    func hear(_ bytes: [UInt8]) {
      guard let status = bytes.first, status >= 0x80, status < 0xF0 else { return }
      onMessage?(bytes)
      guard bytes.count == 3 else { return }
      switch status & 0xF0 {
      case 0x90: onNote?(Int(bytes[1]), Double(bytes[2]) / 127)
      case 0x80: onNote?(Int(bytes[1]), 0)
      default: break
      }
    }
  }
#endif
