/// The groovebox's guide on Windows: the reference's topics, saying what the drawn app's own
/// controls do — its chips, its right-click menus, its menu bar and Ctrl — and leaving out what
/// only the Mac or the web has.
extension GrooveboxHelp {
  static let windows = HelpGuide(
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
                "Open a song", "from File ▸ Open Catalogue Song, or make your own with File ▸ New."),
              HelpStep("Press Space to play,", "and again to stop."),
              HelpStep("Click steps", "in a drum lane: off, on, accented, and off again."),
              HelpStep(
                "Shape the sound.", "Click a lane's name for its knobs, and a 303 line's for the bass."),
              HelpStep(
                "Build the song.",
                "Right-click a pattern's chip and choose Add to Song to put it at the end of the song strip."),
            ])),
          HelpPart(
            "Read the window",
            .terms([
              HelpTerm(
                "Top bar",
                "PLAY and TOP, the song's name, its tempo and swing, where the song is, and AUTO, FX, CLICK "
                  + "and LOOP."),
              HelpTerm(
                "Song strip",
                "The song's sections in order, each as wide as its bars and coloured by its pattern. Click one "
                  + "to go to it; a bracket over it shows a loop."),
              HelpTerm(
                "Pattern bar",
                "FOLLOW, a chip for each pattern, and + for a new one. The chip lit is the pattern shown."),
              HelpTerm(
                "Grid",
                "The pattern shown: a lane for each drum voice it uses, the PCF lane, then the two 303 lines. The "
                  + "lit column is the step playing. The wheel scrolls it; Shift and the wheel scroll it sideways."
              ),
              HelpTerm(
                "Right", "The knobs of the voice or 303 chosen, or the song's effects when FX is lit."),
              HelpTerm(
                "Everywhere else",
                "The window is a filter pad: press and drag anywhere away from the controls to sweep the filter, "
                  + "and let go for it to spring back."),
            ])),
          HelpPart(
            "Easy to miss",
            .terms([
              HelpTerm(
                "Knobs",
                "Drag up and down; hold Alt for fine steps. Click one twice quickly to put it back where it "
                  + "started."),
              HelpTerm("Numbers", "The tempo and the swing are dragged up and down too."),
              HelpTerm(
                "Right-click",
                "A drum lane, a 303 line, a pattern's chip or a section of the song strip has a menu of what can "
                  + "be done to it."),
              HelpTerm(
                "Tab",
                "Puts the controls away, and the whole window is the visuals and the pad. Tab again brings them "
                  + "back."),
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
                "Two bass synths, a line each: two octaves of notes, and a row each for accent and slide."),
              HelpTerm(
                "Pattern bar",
                "Click a chip to show that pattern, or FOLLOW to show whichever is playing. + makes a new, empty "
                  + "one. Right-click a chip to rename it, add it to the song, duplicate it or remove it."),
            ])),
          HelpPart(
            "Drums",
            .terms([
              HelpTerm("Steps", "A click goes off, on, accented, and round again."),
              HelpTerm(
                "Flam",
                "On the 909, Alt-click a step for a second strike close behind the first, and again to take it "
                  + "off."),
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
                "Notes", "Click a cell to put the note there; click it again to rest it, keeping its pitch."),
              HelpTerm(
                "Accent and slide",
                "Click the row under a step. Accent strikes it harder and brighter; slide holds the note into the "
                  + "next and glides to it rather than striking it again."),
              HelpTerm(
                "Its menu",
                "Right-click the line: rotate it, move it by octaves or semitones, randomise, alter or clear it, "
                  + "and copy, cut or paste it."),
            ])),
        ]),
      HelpTopic(
        "song", "Song & automation",
        [
          HelpPart(
            "The song strip",
            .prose([
              "Each block is a section: a pattern, and how many bars it repeats. Click one to go to it. "
                + "Right-click it to play from it, loop it, change its pattern or how often it repeats, give one "
                + "machine another pattern's part in it, move it or take it out."
            ]),
            note:
              "A pattern is material to use again; a section says what plays, for how long, and in what order."
          ),
          HelpPart(
            "Looping",
            .terms([
              HelpTerm(
                "A section",
                "LOOP in the top bar, Transport ▸ Loop This Section (Ctrl+L), or Loop This Section from its menu."
              ),
              HelpTerm(
                "Longer", "Stretch Loop to Here, from another section's menu, takes the loop on to it."),
              HelpTerm(
                "Stopping", "Transport ▸ Clear Loop (Ctrl+Shift+L), or Clear Loop from a section's menu."),
            ])),
          HelpPart(
            "Automation",
            .steps([
              HelpStep("Light AUTO", "in the top bar, or choose Transport ▸ Record Automation."),
              HelpStep("Play,", "and turn a knob, or drag the tempo or the swing."),
              HelpStep(
                "Play it again.", "What you turned is in the song, where the song was when you turned it."),
            ]),
            note:
              "AUTO counts the lanes recorded. Transport ▸ Clear Automation empties them, and Ctrl+Z brings them "
              + "back."),
          HelpPart(
            "Transport",
            .terms([
              HelpTerm(
                "Tempo and swing",
                "The tempo is the song's. Swing holds back every other sixteenth; each voice's own swing, among its "
                  + "OUT knobs, says how far it follows."),
              HelpTerm(
                "CLICK and Count In",
                "The metronome (Ctrl+M), and Transport ▸ Count In for a bar of it before playing from a stop."
              ),
              HelpTerm(
                "MIDI clock",
                "In the MIDI menu: follow a clock from outside — tempo, start and stop — or send one, and where to."
              ),
            ])),
        ]),
      HelpTopic(
        "sound", "Sound, MIDI & files",
        [
          HelpPart(
            "Voices and the 303s",
            .terms([
              HelpTerm(
                "A voice",
                "Click its name for its knobs; HIT IT plays it. Click the name again, or ×, to put them away."
              ),
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
            "Keys and MIDI",
            .terms([
              HelpTerm(
                "Typing keys",
                "The home row plays the 303 whose knobs are showing, or 303 A, and the number row strikes the drum "
                  + "voices in the grid's order."),
              HelpTerm(
                "A MIDI keyboard",
                "Notes from A1 up play the 303, the notes below them the drums. Hit hard, a note is accented."
              ),
              HelpTerm(
                "The MIDI menu",
                "Whether to listen to MIDI, and which inputs; and the clock, followed or sent."),
              HelpTerm(
                "The Audio menu", "What to play through: the system's output, or a device of your own."),
            ])),
          HelpPart(
            "Files, sound and pictures",
            .terms([
              HelpTerm(
                "Songs",
                "File ▸ Open (Ctrl+O), Save (Ctrl+S) and Open Recent; or drop a song on the window. A song is a "
                  + ".driftbox file, and the web app's songs open as they are."),
              HelpTerm(
                "Export",
                "Mix (Ctrl+E) renders the song mastered; Stems (Ctrl+Shift+E) a file per voice, before the "
                  + "master; Movie (Ctrl+Shift+M) the song with its visuals."),
              HelpTerm(
                "Record Performance",
                "(Ctrl+Shift+R) keeps what you play and turn, and writes it as a movie when you stop."),
              HelpTerm(
                "Visuals",
                "View ▸ Visuals Window (Ctrl+2) is a window for a second screen or a projector, full screen from "
                  + "View ▸ Visuals Full Screen On; F11 or a double-click there, and Esc to leave. Next and "
                  + "Previous Scene are Ctrl+Right and Ctrl+Left."),
              HelpTerm("Rack", "Rack ▸ Show Rack (Ctrl+R) is the modular rack, which has its own guide."),
            ])),
        ]),
      HelpTopic(
        "keys", "Shortcuts",
        [
          HelpPart(
            "Playing",
            .keys([
              HelpKey("Space", "Play or stop"),
              HelpKey("Home", "Back to the start"),
              HelpKey("Page Up  Page Down", "The previous or the next section"),
              HelpKey("Ctrl+L", "Loop the section playing"),
              HelpKey("Ctrl+Shift+L", "Clear the loop"),
              HelpKey("Ctrl+M", "Metronome"),
              HelpKey("Ctrl+Z  Ctrl+Y", "Undo, redo"),
            ])),
          HelpPart(
            "Keys",
            .keys([
              HelpKey("A S D F G H J K", "The 303's minor scale, up from its root, A"),
              HelpKey("W R T U I", "The notes between"),
              HelpKey("Z  X", "An octave down or up"),
              HelpKey("1 … =", "The drum voices, in the grid's order"),
            ])),
          HelpPart(
            "Windows and files",
            .keys([
              HelpKey("Tab", "Put the controls away, or bring them back"),
              HelpKey("Ctrl+Left  Ctrl+Right", "The previous or the next scene"),
              HelpKey("Ctrl+2  Ctrl+R", "Visuals, Rack"),
              HelpKey("Ctrl+E  Ctrl+Shift+E  Ctrl+Shift+M", "Export the mix, the stems, a movie"),
              HelpKey("Ctrl+Shift+R", "Record a performance"),
              HelpKey("F1", "This guide"),
            ])),
          HelpPart(
            "With a screen reader",
            .keys([
              HelpKey("Tab  Shift+Tab", "The next or the previous control"),
              HelpKey("Enter", "Press it"),
              HelpKey("Arrows", "Turn a knob or a number a notch"),
            ]),
            note:
              "While a screen reader runs, Tab moves between the controls; Show Controls stays in the View menu."
          ),
        ]),
    ])
}
