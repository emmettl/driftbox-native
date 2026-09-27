import DriftboxHelp
import DriftboxRack

/// What a guided tour looks at: the rack as it stands. A step is done when this says so, and never
/// because the tour did anything itself.
public struct RackTourState: Equatable, Sendable {
  public var patch: Patch
  /// The rack's transport is running.
  public var playing: Bool
  /// The back is showing.
  public var flipped: Bool
  /// How many notes are sounding.
  public var sounding: Int

  public init(patch: Patch, playing: Bool, flipped: Bool, sounding: Int) {
    self.patch = patch
    self.playing = playing
    self.flipped = flipped
    self.sounding = sounding
  }
}

/// What a step points at, where the platform can point: a control of the header's, a card in the
/// modules to add, or a module of a type.
public enum RackTourSpot: Equatable, Sendable {
  case transport, flip
  case add(String)
  case module(String)
}

public struct RackTourStep: Sendable {
  public var id: String
  /// Where to look: a couple of words, for a chip.
  public var place: String
  /// What to do, in one line.
  public var title: String
  /// Why, or what just happened: two sentences at most.
  public var body: String
  public var spot: RackTourSpot?
  let check: @Sendable (_ state: RackTourState, _ baseline: RackTourState) -> Bool

  public func isDone(_ state: RackTourState, from baseline: RackTourState) -> Bool { check(state, baseline) }
}

/// A guided tour of the rack: the reference's `tutorials.ts`, lesson for lesson but for its automation
/// one, which is the web's rack's alone; a small patch to start from, and steps that tick themselves
/// as the person does them, in their own words for each platform.
public struct RackTour: Sendable, Identifiable {
  public var id: String
  public var name: String
  public var blurb: String
  /// About how long, for the card: short or not short.
  public var minutes: Int
  /// The patch it starts from, with what the lesson needs and no more.
  public var setup: Patch
  public var steps: [RackTourStep]
}

// MARK: - What the steps look for

/// The reference's predicates over a patch, by module type throughout, since the ids are the person's:
/// they added the module, so it is `ladder-3` and no step could have known that.
public enum RackTourChecks {
  static func of(_ patch: Patch, _ type: String) -> [PatchModule] { patch.modules.filter { $0.type == type } }

  public static func has(_ patch: Patch, _ type: String) -> Bool {
    patch.modules.contains { $0.type == type }
  }

  /// A cable out of a module of `fromType` into one of `toType`, at the ports named where they are.
  public static func patched(
    _ patch: Patch, _ fromType: String, _ toType: String? = nil, toPort: String? = nil,
    fromPort: String? = nil
  ) -> Bool {
    let from = Set(of(patch, fromType).map(\.id))
    let to = toType.map { Set(of(patch, $0).map(\.id)) }
    return patch.cables.contains { cable in
      from.contains(cable.from.module) && (fromPort == nil || cable.from.port == fromPort)
        && (to?.contains(cable.to.module) ?? true) && (toPort == nil || cable.to.port == toPort)
    }
  }

  /// Whether anything of `type` has a path down audio cables to a terminal module, an Out: plugged in
  /// is not the question anybody means, since a filter cabled into a delay cabled into nothing is
  /// plugged in and silent. Loops are allowed, so the walk keeps what it has seen.
  public static func audible(_ patch: Patch, _ type: String) -> Bool {
    var downstream: [String: [String]] = [:]
    for cable in patch.cables where isAudioInlet(cable.to.port) {
      downstream[cable.from.module, default: []].append(cable.to.module)
    }
    let terminal = Set(
      patch.modules.filter { RackModules.registry[$0.type]?.terminal == true }.map(\.id))
    for start in of(patch, type) {
      var seen: Set<String> = [start.id]
      var queue = [start.id]
      while let at = queue.popLast() {
        for next in downstream[at] ?? [] {
          if terminal.contains(next) { return true }
          if seen.insert(next).inserted { queue.append(next) }
        }
      }
    }
    return false
  }

  /// `in`, `in2` and on, and an effect's returns: the inlets that carry sound rather than control.
  static func isAudioInlet(_ port: String) -> Bool {
    if port == "returnA" || port == "returnB" { return true }
    guard port.hasPrefix("in") else { return false }
    return port.dropFirst(2).allSatisfy(\.isNumber)
  }

  /// A knob of a module of `type` moved off where it started: where the lesson's patch had it, or
  /// its default for a module added since.
  public static func moved(_ patch: Patch, _ type: String, _ param: String? = nil, from baseline: Patch)
    -> Bool
  {
    guard let def = RackModules.registry[type] else { return false }
    return of(patch, type).contains { module in
      zip(module.params.keys, module.params.values).contains { id, value in
        guard param == nil || id == param, let spec = def.params.first(where: { $0.id == id }), !spec.hidden
        else { return false }
        let initial = baseline.modules.first { $0.id == module.id }?.params[id] ?? spec.defaultValue
        return initial != value
      }
    }
  }

  /// A Seq's pitch and gate both into one Voice: pitch alone is a silent patch.
  public static func sequencedVoice(_ patch: Patch) -> Bool {
    of(patch, "voice").contains { voice in
      of(patch, "seq").contains { seq in
        ["pitch", "gate"].allSatisfy { port in
          patch.cables.contains {
            $0.from.module == seq.id && $0.from.port == port && $0.to.module == voice.id && $0.to.port == port
          }
        }
      }
    }
  }

  /// A Combinator's `rotary` routed onto a knob that is there.
  public static func routed(_ patch: Patch, _ rotary: String) -> Bool {
    of(patch, "combi").contains { combi in
      patch.modulation.contains { route in
        route.from.module == combi.id && route.from.port == rotary
          && patch.modules.contains { target in
            target.id == route.to.module
              && RackModules.registry[target.type]?.params.contains { $0.id == route.to.port } == true
          }
      }
    }
  }

  /// An LFO's Bi into a Ladder's Cutoff, and the trim on that input turned down from where it was.
  static func trimmedDown(_ patch: Patch, from baseline: Patch) -> Bool {
    of(patch, "ladder").contains { ladder in
      let fed = patch.cables.contains { cable in
        cable.to.module == ladder.id && cable.to.port == "cutoff" && cable.from.port == "bi"
          && of(patch, "lfo").contains { $0.id == cable.from.module }
      }
      let trim = ladder.inputTrims["cutoff"] ?? 1
      let before = baseline.modules.first { $0.id == ladder.id }?.inputTrims["cutoff"] ?? 1
      return fed && abs(trim) < 1 && trim != before
    }
  }
}

// MARK: - The tours

extension RackTour {
  /// Every tour, in `platform`'s words.
  public static func all(for platform: HelpPlatform) -> [RackTour] {
    let say = Words(platform)
    return [
      RackTour(
        id: "first-sound", name: "A sound of your own",
        blurb: "Add an instrument and play it. Nothing to patch yet.",
        minutes: 3, setup: setup("first-sound"),
        steps: [
          step(
            "voice", say.addPlace, say.add("Sources", "Voice"),
            "A Voice is a whole synth in one module. It arrives wired to an Out of its own; the keys give it notes.",
            spot: .add("voice")
          ) { state, _ in RackTourChecks.has(state.patch, "voice") },
          step(
            "play", say.keysPlace, say.playKeys,
            "The first note makes a MIDI module and wires it to the newest instrument, which is why this works "
              + "before anything is patched."
          ) { state, _ in state.sounding > 0 && RackTourChecks.audible(state.patch, "voice") },
          step(
            "flip", say.flipPlace, say.flip,
            "Two cables you did not draw: pitch and gate, from the MIDI module to the Voice. Every convenience "
              + "in the rack is an ordinary cable you can move or pull out.", spot: .flip
          ) { state, _ in state.flipped },
          step(
            "knob", "Voice", "Turn back, and move a knob on the Voice.", say.knobs, spot: .module("voice")
          ) { state, baseline in RackTourChecks.moved(state.patch, "voice", from: baseline.patch) },
        ]),
      RackTour(
        id: "patch-by-hand", name: "Your first cable",
        blurb: "A filter arrives connected to nothing. Wire it in.",
        minutes: 4, setup: setup("patch-by-hand"),
        steps: [
          step(
            "ladder", say.addPlace, say.add("Filters", "Ladder"),
            "The lesson's Voice repeats on its own: \(say.playTransport) to hear it. The Ladder stays silent "
              + "until it is wired into that path.", spot: .add("ladder")
          ) { state, _ in RackTourChecks.has(state.patch, "ladder") },
          step(
            "flip", say.flipPlace, say.flip,
            "The inputs and outputs are on the back. Drag between two jacks either way: an output can feed many "
              + "inputs, an input takes one cable, and a second replaces the first.", spot: .flip
          ) { state, _ in state.flipped },
          step(
            "in", "The back", "Patch the Voice's Out into the Ladder's In.",
            "The Voice keeps playing through its old cable until the next step replaces it at the Out.",
            spot: .module("ladder")
          ) { state, _ in
            RackTourChecks.patched(state.patch, "voice", "ladder", toPort: "in", fromPort: "out")
          },
          step(
            "out", "The back", "Patch the Ladder's Out into the Out's In.",
            "The chain is whole again, with the filter in the middle of it. An Out is the only way sound leaves "
              + "the rack.", spot: .module("ladder")
          ) { state, _ in
            RackTourChecks.patched(state.patch, "voice", "ladder", toPort: "in", fromPort: "out")
              && RackTourChecks.audible(state.patch, "ladder")
          },
          step(
            "cutoff", "Ladder", "Turn back, and close the Ladder's Cutoff.",
            "Then bring the Res up. This is the 303's filter: four poles, saturating, and near the top of Res it "
              + "sings on its own.", spot: .module("ladder")
          ) { state, baseline in RackTourChecks.moved(state.patch, "ladder", "cutoff", from: baseline.patch)
          },
        ]),
      RackTour(
        id: "make-it-move", name: "Make it move",
        blurb: "An LFO into a control input, and how to set the depth.",
        minutes: 4, setup: setup("make-it-move"),
        steps: [
          step(
            "lfo", say.addPlace, say.add("Modulation", "LFO"),
            "\(say.playTransport.capitalisedFirst) to hear the lesson's filtered Voice. An LFO makes a slow "
              + "control signal to move its filter.", spot: .add("lfo")
          ) { state, _ in RackTourChecks.has(state.patch, "lfo") },
          step(
            "patch", "The back", "Patch the LFO's Bi into the Ladder's Cutoff.",
            "Bi swings either side of nothing, so the filter moves up and down about wherever its knob is. Uni "
              + "only ever adds.", spot: .module("lfo")
          ) { state, _ in
            RackTourChecks.patched(state.patch, "lfo", "ladder", toPort: "cutoff", fromPort: "bi")
              && RackTourChecks.audible(state.patch, "ladder")
          },
          step(
            "rate", "LFO", "Set the LFO's Rate.",
            "Below about 20 Hz it is movement; above that it stops being a wobble and becomes a tone.",
            spot: .module("lfo")
          ) { state, baseline in RackTourChecks.moved(state.patch, "lfo", "rate", from: baseline.patch) },
          step(
            "shape", "LFO", "Change its Shape.",
            "A triangle sweeps, a square switches between two places, and the stepped shape holds a random "
              + "value until the next cycle.", spot: .module("lfo")
          ) { state, baseline in RackTourChecks.moved(state.patch, "lfo", "shape", from: baseline.patch) },
          step(
            "trim", "The back", "Turn down the trim beside the Cutoff input.",
            "The pot beside every input scales what arrives, and past the middle turns it over. It is how to have "
              + "some of the movement rather than all of it."
          ) { state, baseline in RackTourChecks.trimmedDown(state.patch, from: baseline.patch) },
        ]),
      RackTour(
        id: "sequence-it", name: "Let it play itself",
        blurb: "A clock, eight steps, and something to point them at.",
        minutes: 5, setup: setup("sequence-it"),
        steps: [
          step(
            "seq", say.addPlace, say.add("Sequencing", "Seq"),
            "Eight pitch knobs with a switch under each. There is no clock inside it, which is why it does nothing "
              + "yet.", spot: .add("seq")
          ) { state, _ in RackTourChecks.has(state.patch, "seq") },
          step(
            "transport", say.addPlace, say.add("Sequencing", "Transport"),
            "The Transport knows the tempo in the header and makes bars, beats and sixteenths of it, so a patch "
              + "keeps to the tempo rather than to itself.", spot: .add("transport")
          ) { state, _ in RackTourChecks.has(state.patch, "transport") },
          step(
            "clock", "The back", "Patch the Transport's 1/16 into the Seq's Clock.",
            "One pulse, one step. Patch the same 1/16 into a second sequencer and the two stay together for ever.",
            spot: .module("seq")
          ) { state, _ in
            RackTourChecks.patched(state.patch, "transport", "seq", toPort: "clock", fromPort: "sixteenth")
          },
          step(
            "pitch", "The back",
            "Patch the Seq's Pitch into the Voice's V/Oct, and its Gate into the Voice's Gate.",
            "Pitch says which note, the gate when and for how long: two cables, since plenty of patches want one "
              + "without the other.", spot: .module("seq")
          ) { state, _ in RackTourChecks.sequencedVoice(state.patch) },
          step(
            "play", say.transportPlace, say.playTransport.capitalisedFirst + ".",
            "The Transport gives a steady pulse. The Voice's Decay and Release shape each note, and a step switched "
              + "off is a rest.", spot: .transport
          ) { state, _ in
            state.playing && RackTourChecks.sequencedVoice(state.patch)
              && RackTourChecks.audible(state.patch, "voice")
          },
          step(
            "line", "Seq", "Write a line: move the pitch knobs, and switch some steps off.",
            "The rests are what make it a riff rather than a scale.", spot: .module("seq")
          ) { state, baseline in RackTourChecks.moved(state.patch, "seq", from: baseline.patch) },
        ]),
      RackTour(
        id: "macros", name: "Four knobs that play the patch",
        blurb: "The Combinator, and why it holds nothing.",
        minutes: 4, setup: setup("macros"),
        steps: [
          step(
            "combi", say.addPlace, say.add("Modulation", "Combinator"),
            "Four rotaries and four buttons that reach any knob anywhere in the rack. It points at modules rather "
              + "than holding them, which is why nothing needs to be inside it.", spot: .add("combi")
          ) { state, _ in RackTourChecks.has(state.patch, "combi") },
          step(
            "route", "Combinator", "Open Routing… and aim Rotary 1 at a knob.",
            "Try the Ladder's Cutoff, from 300 to 2400. The knob keeps its own place and can still be turned; the "
              + "routing decides where it is.", spot: .module("combi")
          ) { state, _ in RackTourChecks.routed(state.patch, "rotary1") },
          step(
            "range", "Combinator", "Aim Rotary 2 somewhere else.",
            "Try the Voice's Release, from 0.08 to 0.6 seconds, and \(say.playTransport) to hear both on the "
              + "repeating line.", spot: .module("combi")
          ) { state, _ in
            RackTourChecks.routed(state.patch, "rotary1") && RackTourChecks.routed(state.patch, "rotary2")
          },
          step(
            "turn", "Combinator", "Turn Rotary 1, and listen.",
            "A knob under a routing is marked on its own face, so what is moving a knob you did not touch can "
              + "always be found.", spot: .module("combi")
          ) { state, baseline in RackTourChecks.moved(state.patch, "combi", "rotary1", from: baseline.patch)
          },
        ]),
    ]
  }

  static func step(
    _ id: String, _ place: String, _ title: String, _ body: String, spot: RackTourSpot? = nil,
    done: @escaping @Sendable (RackTourState, RackTourState) -> Bool
  ) -> RackTourStep {
    RackTourStep(id: id, place: place, title: title, body: body, spot: spot, check: done)
  }

  /// A lesson's patch: the factory's Pocket Sequence cut down to a Voice and an Out, with its Transport
  /// and Seq where the lesson is not about building those, and a Ladder in the way where it is about
  /// what goes through one. The first is empty.
  static func setup(_ id: String) -> Patch {
    var patch = Patch(modules: [], cables: [])
    patch.tempo = 108
    guard id != "first-sound", let seed = PatchEntry.all.first(where: { $0.id == "pocket-sequence" })?.load()
    else { return patch }
    let sequenced = id != "sequence-it"
    let filtered = ["make-it-move", "macros"].contains(id)
    let kept = ["voice", "out"] + (sequenced ? ["transport", "seq"] : [])
    patch.modules = seed.modules.filter { kept.contains($0.type) }
    let ids = Set(patch.modules.map(\.id))
    patch.cables = seed.cables.filter {
      sequenced && ["clock", "pitch", "gate"].contains($0.to.port) && ids.contains($0.from.module)
        && ids.contains($0.to.module)
    }
    let voice = patch.modules.first { $0.type == "voice" }?.id ?? "voice-1"
    let out = patch.modules.first { $0.type == "out" }?.id ?? "out-1"
    if filtered {
      patch.modules.append(PatchModule(id: "ladder-1", type: "ladder"))
      patch.cables += [
        PatchCable(from: PortReference(voice, "out"), to: PortReference("ladder-1", "in")),
        PatchCable(from: PortReference("ladder-1", "out"), to: PortReference(out, "in")),
      ]
    } else {
      patch.cables.append(PatchCable(from: PortReference(voice, "out"), to: PortReference(out, "in")))
    }
    return patch
  }

  /// What differs between the platforms' words: how a module is added, the rack turned round, the keys
  /// played and the transport started.
  struct Words {
    let platform: HelpPlatform
    init(_ platform: HelpPlatform) { self.platform = platform }

    var addPlace: String { platform == .mac ? "Add" : "ADD" }
    func add(_ group: String, _ name: String) -> String {
      switch platform {
      case .mac: "Press Add, and choose \(name), under \(group)."
      case .windows, .android: "ADD › \(group) › \(name)."
      }
    }
    var flipPlace: String {
      switch platform {
      case .mac, .windows: "Tab"
      case .android: "BACK"
      }
    }
    var flip: String {
      switch platform {
      case .mac, .windows: "Press Tab to turn the rack round."
      case .android: "Tap BACK to turn the rack round."
      }
    }
    var keysPlace: String { platform == .android ? "KEYS" : "The keys" }
    var playKeys: String {
      switch platform {
      case .mac, .windows: "Play the typing keys: Z to M, and Q to U."
      case .android: "Tap KEYS, and play the keys along the foot."
      }
    }
    var transportPlace: String { platform == .mac ? "Play" : "PLAY" }
    var playTransport: String {
      switch platform {
      case .mac: "press Space, or Play"
      case .windows: "press Space, or PLAY"
      case .android: "tap PLAY"
      }
    }
    var knobs: String {
      switch platform {
      case .mac:
        "Drag it up and down; Option is fine movement, the arrow keys move one with focus, and a double-click "
          + "puts it back where it started."
      case .windows:
        "Drag it up and down; Alt is fine movement, and a double-click puts it back where it started."
      case .android:
        "Drag it up and down with a finger; a double tap puts it back where it started."
      }
    }
  }
}

extension String {
  /// With its first letter a capital.
  var capitalisedFirst: String { prefix(1).uppercased() + dropFirst() }
}
