/// The rack's guide: the reference's `HelpDialog` for the rack, topic for topic, saying what this
/// platform's rack does. What the web's rack has and this one has not — a library in the browser, a
/// link to share, its automation desk and performance views — is left out rather than described.
public enum RackHelp {
  public static func guide(for platform: HelpPlatform) -> HelpGuide {
    var guide =
      switch platform {
      case .mac: mac
      case .windows: windows
      case .android: android
      }
    guide.topics.insert(learningPath(for: platform), at: 1)
    return guide
  }

  static let mac = HelpGuide(
    title: "Rack guide",
    topics: [
      HelpTopic(
        "start", "Start here",
        [
          HelpPart(
            "The mental model",
            .prose([
              "The rack is a modular instrument. Sources make sound or control; processors change it; "
                + "sequencers and MIDI decide the notes and the time; a Mixer and an Out deliver the result. The "
                + "cables, not the order the modules sit in, say what runs into what."
            ]),
            note:
              "If a patch is silent, trace one path from its source through what it passes to an Out, then "
              + "check the gates, the levels and the meters."),
          HelpPart(
            "Patch something",
            .steps([
              HelpStep("Open a patch", "from the Patch menu in the header: the factory patches, by kind."),
              HelpStep("Turn the rack round", "with Back, or Tab. The inputs and outputs are on the back."),
              HelpStep(
                "Drag from a jack to a jack.", "A basic path is a source, a filter or an effect, then an Out."
              ),
              HelpStep("Play it", "on the typing keys, from a sequencer module, or from a MIDI keyboard."),
            ])),
          HelpPart(
            "Front, back and header",
            .terms([
              HelpTerm(
                "Header", "The patch, the transport, the typing keys' octave, Back or Front, and Add."),
              HelpTerm("Front", "Every module's controls, its screens and meters."),
              HelpTerm(
                "Back",
                "Every module's jacks, inputs down the left in teal and outputs down the right in amber, the "
                  + "cables between them, and a trim beside each input."),
              HelpTerm(
                "Add", "Every module there is, on its shelf and searchable, each with its picture and a line."
              ),
            ])),
          HelpPart(
            "First useful choices",
            .terms([
              HelpTerm(
                "A synth?",
                "Add a Voice for a whole instrument, or MIDI, a VCO, a VCA and an ADSR to build one."),
              HelpTerm(
                "Drums?",
                "Open a groovebox song from the Patch menu, or load your own recording into a Sampler."),
              HelpTerm(
                "Movement?",
                "Patch an LFO or an envelope into a control input, or have a Combinator turn several knobs at once."
              ),
              HelpTerm(
                "A whole track?", "Open a factory patch: its meters and names show how it is meant to flow."),
            ])),
        ]),
      HelpTopic(
        "patching", "Patching & modules",
        [
          HelpPart(
            "Cables",
            .terms([
              HelpTerm(
                "Output to input",
                "Drag from either end; it snaps to the jack it can reach. An output can feed many inputs; an input "
                  + "takes one cable."),
              HelpTerm("Unplugging", "Click a cable, or the × beside the input it is in."),
              HelpTerm("Stereo into mono", "Only the left channel reaches a mono input."),
              HelpTerm(
                "Feedback", "Loops are allowed: the rack puts one block's delay in them so that they can run."
              ),
            ])),
          HelpPart(
            "The back",
            .terms([
              HelpTerm(
                "Input trim",
                "The pot beside every input scales what arrives, or turns it upside down. Drag it up and down; "
                  + "double-click puts it back to 1×."),
              HelpTerm("Moving", "Drag a module's bay to move it; its cables swing after it."),
              HelpTerm(
                "Control and sound",
                "Both are signals on cables. A pitch, a gate, an envelope or an LFO is control only because of the "
                  + "input that receives it."),
              HelpTerm(
                "Levels",
                "A VU Meter, as a needle, lights or a wave, finds silence or clipping; a VCA, a Mixer, a trim or a "
                  + "Limiter tames it."),
            ])),
          HelpPart(
            "Modules",
            .terms([
              HelpTerm("Selecting", "Click a module; ⌘-click adds another to the selection."),
              HelpTerm(
                "Its menu",
                "Right-click a module for its guide, to move it up or down, bypass it, duplicate it or remove it."
              ),
              HelpTerm(
                "Bypass and duplicate",
                "Bypassed, a processor passes its input on untouched. A duplicate copies the settings and none of "
                  + "the cables."),
              HelpTerm(
                "Undo",
                "Edit ▸ Undo, while the rack's window is in front, undoes the rack's cables, moves and knobs."
              ),
            ])),
          HelpPart(
            "Controls",
            .terms([
              HelpTerm(
                "Knobs",
                "Drag up and down; hold Option for fine steps. Double-click puts one back where it started; the "
                  + "arrow keys move one that has focus."),
              HelpTerm(
                "Driven",
                "A knob a Combinator drives is marked as driven, and moves as its rotary or button does."),
              HelpTerm(
                "Recordings",
                "Drop a recording on a Sampler, a Multisample Instrument or an Audio Track, or click its screen to "
                  + "choose one."),
            ])),
        ]),
      HelpTopic(
        "modules", "Module map",
        [
          HelpPart(
            "Sources",
            .terms([
              HelpTerm(
                "Groovebox", "A groovebox song's 808, 909 and two 303s, each machine on outputs of its own."),
              HelpTerm(
                "VCO, Wavetable, Voice, Noise",
                "Oscillators to build with, a whole playable synth voice, and noise."),
              HelpTerm(
                "Sampler, Multisample Instrument",
                "Slice Lab, one recording cut into slices; and Key Atlas, a set of recordings mapped across the keys."
              ),
              HelpTerm(
                "Audio Track",
                "One recording started at a bar and a step of the rack's transport, out on cables."),
              HelpTerm(
                "Audio Input",
                "What comes in from a microphone or an interface, chosen in Settings under Audio In. Wear "
                  + "headphones."),
              HelpTerm(
                "Plug-in, Plug-in Instrument",
                "An Audio Unit effect or instrument from this Mac, with its own controls a click away."),
            ])),
          HelpPart(
            "Shape and space",
            .terms([
              HelpTerm(
                "Filters",
                "Ladder and SVF take frequencies away; Alligator gates bands in rhythm; the Vocoder puts one "
                  + "signal's spectrum on another."),
              HelpTerm(
                "Level and colour",
                "VCA, Drive, Distortion, Amp / Cab, EQ, Stereo Imager, Comp and Limiter shape gain, tone, width "
                  + "and peaks."),
              HelpTerm(
                "Time",
                "Delay, Ping-Pong Delay, Phaser, Reverb and the Loop Station make repeats, movement, space or "
                  + "phrases."),
              HelpTerm(
                "Order matters",
                "A filter before a distortion sounds unlike one after it. The cables decide the order."),
            ])),
          HelpPart(
            "Control and modulation",
            .terms([
              HelpTerm(
                "ADSR and LFO",
                "A shape each note, and a movement that repeats. Into a control input, through a VCA or a trim where "
                  + "the depth matters."),
              HelpTerm(
                "Follower, S&H",
                "Loudness made into control; a moving signal made into steps."),
              HelpTerm(
                "Offset, Quantizer", "Shift or turn over a signal; then hold a pitch to the notes of a scale."
              ),
              HelpTerm(
                "Combinator",
                "Four rotaries and buttons that turn other modules' knobs. Routing… on its face sets which, and "
                  + "between what."),
            ])),
          HelpPart(
            "Notes, time and routing",
            .terms([
              HelpTerm(
                "Transport and Clock",
                "The Transport knows the tempo and the bars; a Clock makes pulses of them for other modules."),
              HelpTerm(
                "Seq and Tracker",
                "Steps of pitch and gate. The Arranger changes scenes over bars; the Arp, Chord Player, Scale "
                  + "Player and Note Echo change notes."),
              HelpTerm(
                "MIDI", "Notes from the keys or a keyboard, as pitch, gate and velocity, a voice each."),
              HelpTerm(
                "Mixers and Out",
                "A Mixer or a Line Mixer brings paths together; an Out is where sound leaves. The VU Meter and the "
                  + "Chromatic Tuner look without changing anything."),
            ])),
        ]),
      HelpTopic(
        "playing", "Playing",
        [
          HelpPart(
            "Playing the rack",
            .terms([
              HelpTerm(
                "Typing keys",
                "Two rows, from Z and from Q, while the rack's window is in front; comma and full stop move the "
                  + "octave. The header says where it is."),
              HelpTerm(
                "A MIDI keyboard", "Plays the rack while its window is in front, and the groovebox otherwise."
              ),
              HelpTerm(
                "Voices",
                "The MIDI module decides pitch, gate and velocity, and how many notes play at once. Without one, "
                  + "every voice gets the same note."),
            ])),
          HelpPart(
            "The groovebox in the rack",
            .terms([
              HelpTerm(
                "A song whole",
                "Patch ▸ Groovebox Songs opens one in the rack, with its Groovebox module wired in."),
              HelpTerm(
                "Unpatched", "A machine whose output is not patched plays on in the song's own mix."),
              HelpTerm(
                "Patched", "Patch a machine's output and the whole machine goes through the rack instead."),
              HelpTerm(
                "Editing",
                "The Groovebox module opens its song in the groovebox window; every edit plays on here."),
            ])),
          HelpPart(
            "In another app",
            .prose([
              "Driftbox: Rack and Driftbox: Groovebox are Audio Unit instruments in Logic, GarageBand and every "
                + "other app that plays them, each with its face and its presets. Driftbox has to have been opened "
                + "once for them to be found."
            ])),
        ]),
      HelpTopic(
        "silence", "Nothing playing?",
        [
          HelpPart(
            "Check these four, in this order",
            .steps([
              HelpStep(
                "There is sound to be had.",
                "If the header says No sound, the rack could not start its audio; Settings says what it plays "
                  + "through."),
              HelpStep(
                "There is an Out, and the chain reaches it.",
                "An Out is the only way sound leaves the rack. On the back, trace one path from the source to it."
              ),
              HelpStep(
                "Something opens the gate.",
                "A sequencer with no clock, an envelope with no gate, or a VCA whose control never arrives are "
                  + "silent while looking patched."),
              HelpStep(
                "The level is not nothing.",
                "The Out's level, a VCA, a mute, another Out's solo, a filter shut."),
            ]),
            note:
              "Patch a VU Meter in where you are unsure and move it along the chain: where its lights stop is "
              + "where the signal stops."),
          HelpPart(
            "Silent for a reason",
            .terms([
              HelpTerm(
                "An empty sampler", "A Sampler with nothing loaded makes nothing. Drop a recording on it."),
              HelpTerm(
                "Waiting for notes",
                "The Arp and the Chord Player wait for notes from a MIDI module, played on the keys."),
              HelpTerm(
                "A Seq with no clock",
                "A Seq has no clock inside it. Patch a Transport division or a Clock into it."),
              HelpTerm(
                "Audio Input",
                "Listens to the device Settings names under Audio In, and only while the patch has one. Settings "
                  + "says why it hears nothing: the device unplugged, or Privacy & Security keeping the microphone "
                  + "from Driftbox. The rack as an Audio Unit in another app hears nothing."),
              HelpTerm(
                "Bypassed or muted",
                "A bypassed processor passes its input on; a muted Out, or one not soloed while another is, passes "
                  + "nothing."),
            ])),
          HelpPart(
            "Loud, wrong or distorted",
            .terms([
              HelpTerm(
                "Everything at once",
                "Without a MIDI module every voice plays the same note, that many times louder."),
              HelpTerm(
                "Clipping",
                "Several chains into one Out. Lower the Out, or put a Mixer or a Limiter before it."),
              HelpTerm(
                "Too deep",
                "An LFO or an envelope straight into a control input is at full depth. Turn down the trim beside "
                  + "the input, or go through a VCA."),
              HelpTerm("A knob that moves itself", "A Combinator is driving it, and it says so."),
            ])),
        ]),
      HelpTopic(
        "keys", "Patches & shortcuts",
        [
          HelpPart(
            "Patches",
            .terms([
              HelpTerm(
                "The Patch menu",
                "The factory patches, by kind, and the groovebox's songs, whole."),
              HelpTerm("Kept", "The rack keeps the patch it has, and opens on it next time."),
            ])),
          HelpPart(
            "Shortcuts",
            .keys([
              HelpKey("Space", "Start or stop the rack's transport"),
              HelpKey("Tab", "Turn the rack round"),
              HelpKey("Z … M  Q … U", "Two rows of keys"),
              HelpKey(",  .", "The keys' octave down or up"),
              HelpKey("⌘Z  ⇧⌘Z", "Undo, redo"),
              HelpKey("⌘3", "The rack's window"),
              HelpKey("⌥⌘?", "This guide"),
            ])),
        ]),
    ])
}
