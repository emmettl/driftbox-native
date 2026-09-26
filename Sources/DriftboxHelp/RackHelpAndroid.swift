/// The rack's guide on Android: the reference's topics, saying what the rack does under a finger —
/// its chips, pinching and panning, a finger held down for a module's menu, its keys across the foot,
/// a MIDI keyboard, undo in the patch's menu — and leaving out what it has not got: plug-ins, live
/// input, typing keys.
extension RackHelp {
  static let android = HelpGuide(
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
              HelpStep(
                "Show the rack",
                "from the song's chip in the groovebox: Rack. The patch's chip here has the way back, Groovebox."
              ),
              HelpStep("Open a patch", "from the patch's chip: Patches, the factory patches."),
              HelpStep("Turn the rack round", "with BACK. The inputs and outputs are on the back."),
              HelpStep(
                "Drag from a jack to a jack.", "A basic path is a source, a filter or an effect, then an Out."
              ),
              HelpStep(
                "Play it", "on the keys across the foot, from a MIDI keyboard, or from a sequencer module."),
            ])),
          HelpPart(
            "Front, back and header",
            .terms([
              HelpTerm(
                "Header", "The patch's chip, PLAY, the tempo, BACK or FRONT, and ADD."),
              HelpTerm("Front", "Every module's controls, its screens and meters."),
              HelpTerm(
                "Back",
                "Every module's jacks, inputs down the left in teal and outputs down the right in amber, the "
                  + "cables between them, and a trim beside each input."),
              HelpTerm("ADD", "Every module there is, by what it is for."),
            ])),
          HelpPart(
            "Moving about",
            .terms([
              HelpTerm("Pinch", "Zooms in and out, about your fingers."),
              HelpTerm(
                "Drag", "On a panel away from its controls, or between modules, moves the rack about."),
              HelpTerm(
                "Double tap",
                "A module fits it to the screen, a knob a finger's size; again, and the whole rack fits."),
            ])),
          HelpPart(
            "First useful choices",
            .terms([
              HelpTerm(
                "A synth?",
                "Add a Voice for a whole instrument, or MIDI, a VCO, a VCA and an ADSR to build one."),
              HelpTerm("Drums?", "Add a Groovebox module, or load your own recording into a Sampler."),
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
              HelpTerm("Unplugging", "Tap a cable's middle, or the × beside the input it is in."),
              HelpTerm(
                "Stereo into mono", "Only the left channel reaches a mono input; its cable is drawn thinner."),
              HelpTerm(
                "Feedback",
                "Loops are allowed: the rack puts one block's delay in them so that they can run, and draws them "
                  + "dashed."),
            ])),
          HelpPart(
            "The back",
            .terms([
              HelpTerm(
                "Input trim",
                "The pot beside every input scales what arrives, or turns it upside down. Drag it up and down; tap "
                  + "it twice quickly to put it back to 1×."),
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
              HelpTerm("Selecting", "Tap a module."),
              HelpTerm(
                "Its menu",
                "Hold a finger on a module, front or back, for its guide, to move it up or down, bypass it, "
                  + "duplicate it or remove it."),
              HelpTerm(
                "Bypass and duplicate",
                "Bypassed, a processor passes its input on untouched. A duplicate copies the settings and none of "
                  + "the cables."),
              HelpTerm(
                "Undo",
                "Undo and Redo, in the patch's chip's menu, take back the rack's cables, moves and knobs, and say "
                  + "which."),
            ])),
          HelpPart(
            "Controls",
            .terms([
              HelpTerm(
                "Knobs",
                "Drag up and down; a finger going sideways moves the rack instead. Tap one twice quickly to put it "
                  + "back where it started."),
              HelpTerm(
                "Choices and numbers",
                "Tap a choice's button, or step it with ‹ and ›. Drag a number up and down; a tap does what it "
                  + "says."),
              HelpTerm(
                "Driven",
                "A knob a Combinator drives has an amber dot, and moves as its rotary or button does."),
              HelpTerm(
                "Recordings",
                "Tap an empty Sampler, Multisample Instrument or Audio Track to choose a recording, from anywhere "
                  + "Android keeps them. A Multisample Instrument takes a whole set at once."),
            ])),
          HelpPart(
            "A Combinator's routing",
            .terms([
              HelpTerm(
                "Routing…",
                "On the Combinator's face: its routing, across the foot of a phone or beside the rack on a tablet; "
                  + "× puts it away."),
              HelpTerm(
                "A routing",
                "Which of its rotaries or buttons, which module and which knob it turns: each a menu to choose "
                  + "from. Add Routing adds one, and − takes it out."),
              HelpTerm(
                "MIN and MAX", "Drag them up and down: the ends of the knob's travel it turns across."),
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
              HelpTerm("Follower, S&H", "Loudness made into control; a moving signal made into steps."),
              HelpTerm(
                "Offset, Quantizer", "Move or turn over a signal; then hold a pitch to the notes of a scale."
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
                "MIDI",
                "Notes from the keys across the foot or a MIDI keyboard, as pitch, gate and velocity, a voice each."
              ),
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
                "The keys",
                "Across the foot of the screen, when the patch has a MIDI module; KEYS shows them, HIDE puts them "
                  + "away. A key struck lower plays louder, and several fingers play a chord."),
              HelpTerm("The octave", "‹ and › on the keys' row, and it says which C they start from."),
              HelpTerm(
                "A MIDI keyboard",
                "Plays the rack while it shows, and the groovebox otherwise: over USB, or another app's MIDI. Its "
                  + "bend, sustain pedal and other controllers reach the modules listening."),
              HelpTerm(
                "Voices",
                "The MIDI module decides pitch, gate and velocity for each voice. Without one, every voice gets the "
                  + "same note."),
              HelpTerm(
                "Transport", "PLAY in the header starts and stops the rack; the groovebox plays on under it."),
            ])),
          HelpPart(
            "The groovebox in the rack",
            .terms([
              HelpTerm(
                "The Groovebox module",
                "A song's four machines, each on outputs of its own; ▶ plays from a section, and ⟳ loops it."),
              HelpTerm(
                "Unpatched", "A machine whose output is not patched plays on in the song's own mix."),
              HelpTerm(
                "Patched", "Patch a machine's output and the whole machine goes through the rack instead."),
            ])),
          HelpPart(
            "Recordings",
            .terms([
              HelpTerm(
                "A Sampler",
                "Loading a recording sets the rack's tempo so that it is whole bars — 1, 2, 4 or 8, as its buttons "
                  + "choose — and starts the transport."),
              HelpTerm(
                "Kept",
                "Recordings are the rack's while the app is open: a patch opened afresh, or the app next time, "
                  + "needs them loaded again."),
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
                "In the groovebox, the song's chip has Output: what Driftbox plays through, and a device gone."
              ),
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
                "An empty sampler",
                "A Sampler with nothing loaded makes nothing. Tap it to choose a recording."),
              HelpTerm(
                "Waiting for notes",
                "The Arp and the Chord Player wait for notes from a MIDI module, played on the keys or a MIDI "
                  + "keyboard."),
              HelpTerm(
                "A Seq with no clock",
                "A Seq has no clock inside it. Patch a Transport division or a Clock into it."),
              HelpTerm(
                "Bypassed or muted",
                "A bypassed processor passes its input on; a muted Out, or one not soloed while another is, passes "
                  + "nothing."),
              HelpTerm(
                "Not on a phone yet",
                "Audio Input and plug-ins are silent here: live input and plug-ins are still to come on Android."
              ),
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
              HelpTerm("A knob that moves itself", "A Combinator is driving it, and its amber dot says so."),
            ])),
        ]),
      HelpTopic(
        "keys", "Patches & gestures",
        [
          HelpPart(
            "Patches",
            .terms([
              HelpTerm(
                "The patch's chip",
                "Groovebox, the way back; Undo and Redo; Patches, the factory patches; and Rack Guide, this "
                  + "guide."),
              HelpTerm(
                "Kept",
                "The rack keeps the patch it has, and opens on it next time. Opening another patch replaces it."
              ),
            ])),
          HelpPart(
            "Fingers",
            .keys([
              HelpKey("Tap", "Press a chip, a button or a key; select a module"),
              HelpKey("Drag up and down", "Turn a knob, a number or a trim"),
              HelpKey("Drag", "From a jack to a jack, on the back"),
              HelpKey("Pinch", "Zoom"),
              HelpKey("Double tap", "Fit a module to the screen, or the rack; put a knob or a trim back"),
              HelpKey("Hold", "A module's menu"),
            ])),
        ]),
    ])
}
