/// The groovebox's guide on Android: the reference's topics, saying what the touchscreen's own
/// controls do — its chips, a finger held down for a menu, the song's menu from its chip, the step
/// keyboard — and leaving out what it has not got: keys, a menu bar, exports.
extension GrooveboxHelp {
  static let android = HelpGuide(
    title: "Groovebox guide",
    topics: [
      HelpTopic(
        "start", "Start here",
        [
          HelpPart(
            "The mental model",
            .prose([
              "The groovebox is four instruments sharing one song: an 808, a 909 and two 303 bass "
                + "synths. A pattern holds what they play for a bar; the song strip strings patterns "
                + "together, each for as many bars as it repeats."
            ]),
            note: "Every lane plays together. Choosing a voice only chooses whose knobs are showing."),
          HelpPart(
            "Make a beat",
            .steps([
              HelpStep(
                "Open a song",
                "from the song's chip, at the left of the song strip: Songs are the ones Driftbox comes with."
              ),
              HelpStep("Tap PLAY,", "and STOP to stop."),
              HelpStep("Tap steps", "in a drum lane: off, on, accented, and off again."),
              HelpStep(
                "Shape the sound.", "Tap a lane's name for its knobs, and a 303 line's for the bass."),
              HelpStep(
                "Build the song.",
                "Hold a finger on a pattern's chip and choose Add to Song to put it at the end of the song strip."
              ),
            ])),
          HelpPart(
            "Read the screen",
            .terms([
              HelpTerm(
                "Top bar",
                "PLAY and TOP, PERFORM, FX, CLICK and LOOP; on a tablet the song's name, where it has got to, "
                  + "and AUTO too."),
              HelpTerm(
                "Song strip",
                "The song's chip, its tempo and swing, and its sections in order, each as wide as its bars. Tap "
                  + "one to go to it; a bracket over it shows a loop."),
              HelpTerm(
                "Pattern bar",
                "FOLLOW, a chip for each pattern, and + for a new one. The chip lit is the pattern shown."),
              HelpTerm(
                "Grid",
                "The pattern shown: a lane for each drum voice it uses, the PCF lane, then the two 303 lines. Drag "
                  + "up and down to scroll it; swipe sideways, or tap 1–8 and 9–16, for the other steps."),
              HelpTerm(
                "Knobs",
                "The voice or 303 chosen, or the song's effects when FX is lit: across the foot of a phone, or "
                  + "down the right of a tablet on its side."),
              HelpTerm(
                "Everywhere else",
                "The screen is a filter pad: a finger anywhere away from the controls sweeps the filter, and it "
                  + "springs back as the finger lifts. A second finger tapped meanwhile goes on to the next scene."
              ),
            ])),
          HelpPart(
            "Easy to miss",
            .terms([
              HelpTerm(
                "Knobs", "Drag up and down. Tap one twice quickly to put it back where it started."),
              HelpTerm("Tempo and swing", "Dragged up and down too, in the song strip's head."),
              HelpTerm(
                "Hold a finger down",
                "On a drum lane, a 303 line, a pattern's chip or a section of the song strip, for a menu of what "
                  + "can be done to it."),
              HelpTerm(
                "PERFORM",
                "Puts the controls away: the whole screen is the visuals and the pad. EDIT, in the corner, brings "
                  + "them back."),
            ])),
        ]),
      HelpTopic(
        "patterns", "Patterns",
        [
          HelpPart(
            "Patterns and machines",
            .terms([
              HelpTerm("808 and 909", "Each lane is one drum voice the pattern uses."),
              HelpTerm(
                "303 A and B",
                "Two bass synths, a line each: every step a note, which sounds or rests, with an accent and a "
                  + "slide."),
              HelpTerm(
                "Pattern bar",
                "Tap a chip to show that pattern, or FOLLOW to show whichever is playing. + makes a new, empty "
                  + "one. Hold a finger on a chip to rename it, add it to the song, duplicate it or remove it."
              ),
            ])),
          HelpPart(
            "Drums",
            .terms([
              HelpTerm("Steps", "A tap goes off, on, accented, and round again."),
              HelpTerm(
                "PCF",
                "The pattern-controlled filter's lane: each step strikes the song-wide filter's envelope, harder "
                  + "when accented."),
            ])),
          HelpPart(
            "A lane's menu",
            .terms([
              HelpTerm("Rotate", "Moves every hit a step left or right, round the ends."),
              HelpTerm(
                "Randomise and Alter",
                "Randomise writes a new rhythm; Alter moves the one there about, keeping how busy it is."),
              HelpTerm("Clear", "Takes every hit out of the lane."),
              HelpTerm(
                "Copy, Cut, Paste", "A lane pastes into any drum lane, and a 303 line into a 303 line."),
              HelpTerm(
                "Loop Length",
                "Plays the lane round in fewer steps than the pattern, against the others; the steps past it "
                  + "fade."),
            ])),
          HelpPart(
            "303 lines",
            .terms([
              HelpTerm(
                "A step",
                "Tap one for the step keyboard over the grid. A key sets its note, sounds it and goes on to the next "
                  + "step; the note already there rests it, keeping its pitch."),
              HelpTerm(
                "The keyboard's chips",
                "◀ and ▶ step back and on, REST rests the step, ACCENT and SLIDE mark it, the octave chip moves "
                  + "the keys on a phone, and × puts the keyboard away."),
              HelpTerm(
                "Accent and slide",
                "Accent strikes the step harder and brighter; slide holds the note into the next and glides to it "
                  + "rather than striking it again."),
              HelpTerm(
                "Its menu",
                "Hold a finger on the line: rotate it, move it by octaves or semitones, randomise, alter or clear "
                  + "it, and copy, cut or paste it."),
            ])),
        ]),
      HelpTopic(
        "song", "Song & automation",
        [
          HelpPart(
            "The song strip",
            .prose([
              "Each block is a section: a pattern, and how many bars it repeats. Tap one to go to it. Hold a "
                + "finger on it to play from it, loop it, change its pattern or how often it repeats, give one "
                + "machine another pattern's part in it, move it or take it out."
            ]),
            note:
              "A pattern is material to use again; a section says what plays, for how long, and in what order."
          ),
          HelpPart(
            "Looping",
            .terms([
              HelpTerm("A section", "LOOP in the top bar, or Loop This Section from its menu."),
              HelpTerm(
                "Longer", "Stretch Loop to Here, from another section's menu, takes the loop on to it."),
              HelpTerm("Stopping", "Clear Loop, from a section's menu."),
            ])),
          HelpPart(
            "Automation",
            .steps([
              HelpStep("Light AUTO", "in the top bar, on a tablet."),
              HelpStep("Play,", "and turn a knob, or drag the tempo or the swing."),
              HelpStep(
                "Play it again.", "What you turned is in the song, where the song was when you turned it."),
            ]),
            note:
              "AUTO counts the lanes recorded. A phone plays automation back but has no AUTO to record it."),
          HelpPart(
            "Transport",
            .terms([
              HelpTerm(
                "Tempo and swing",
                "The tempo is the song's. Swing holds back every other sixteenth; each voice's own swing, among its "
                  + "OUT knobs, says how far it follows."),
              HelpTerm("CLICK", "The metronome."),
            ])),
        ]),
      HelpTopic(
        "sound", "Sound & files",
        [
          HelpPart(
            "Voices and the 303s",
            .terms([
              HelpTerm(
                "A voice",
                "Tap its name for its knobs; HIT IT plays it. Tap the name again, or ×, to put them away."),
              HelpTerm(
                "OUT", "Each voice's sends to the delay and the reverb, and its swing against the song's."),
              HelpTerm("A and B", "Switch the 303's knobs between the two lines."),
            ])),
          HelpPart(
            "The song's effects",
            .terms([
              HelpTerm("FX", "In the top bar: the song's effects in place of a voice's knobs."),
              HelpTerm(
                "Drive and Comp", "Drive saturates the whole mix; Comp holds its peaks down and glues it."),
              HelpTerm(
                "Filter",
                "The pattern-controlled filter's cutoff, resonance, envelope and decay. The PCF lane says when it "
                  + "strikes."),
              HelpTerm("Delay and Reverb", "The one echo and the one space every voice's sends feed."),
            ])),
          HelpPart(
            "The song's menu",
            .terms([
              HelpTerm("Its chip", "The song's name, at the left of the song strip: tap it."),
              HelpTerm(
                "Open, Save, Save As",
                "Through Android's own picker. A song is a .driftbox file, and the web app's songs open as they "
                  + "are."),
              HelpTerm("Songs", "The ones Driftbox comes with."),
              HelpTerm(
                "Output",
                "What to play through: Automatic, as Android routes it, or a device — the speaker, headphones, "
                  + "USB or Bluetooth. One unplugged stays chosen, and says so."),
              HelpTerm("Rack", "The modular rack, in the groovebox's place, which has its own guide."),
              HelpTerm("Groovebox Guide", "This guide."),
            ])),
          HelpPart(
            "Playing on",
            .prose([
              "The song plays on with the screen off, with a notification to stop it from; a call or another "
                + "app's sound pauses it until it is over."
            ])),
        ]),
      HelpTopic(
        "keys", "Gestures",
        [
          HelpPart(
            "Fingers",
            .keys([
              HelpKey("Tap", "Press a chip, a step or a name"),
              HelpKey("Drag up and down", "Turn a knob, the tempo or the swing; scroll the grid"),
              HelpKey("Swipe sideways", "The other steps of a long pattern"),
              HelpKey("Double tap", "Put a knob back where it started"),
              HelpKey("Hold", "A menu for a lane, a line, a pattern or a section"),
              HelpKey("Off the controls", "The filter pad"),
              HelpKey("A second finger", "The next scene, while the first is on the pad"),
            ])),
          HelpPart(
            "In here",
            .keys([
              HelpKey("Drag", "Scroll the guide"),
              HelpKey("Tap a topic", "Go to it"),
              HelpKey("Close", "Or a tap off the page"),
            ])),
        ]),
    ])
}
