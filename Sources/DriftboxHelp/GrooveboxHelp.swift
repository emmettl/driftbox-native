/// The groovebox's guide: the reference's `HelpDialog` for the groovebox, topic for topic, saying
/// what this platform's controls do. Where the web has something the platform has not — a library
/// in the browser, a link to share — it is left out rather than described.
public enum GrooveboxHelp {
  public static func guide(for platform: HelpPlatform) -> HelpGuide {
    switch platform {
    case .mac: mac
    case .windows: windows
    }
  }

  static let mac = HelpGuide(
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
                "Press Space to play,", "or pick one of the songs Driftbox comes with from the sidebar."),
              HelpStep("Click steps", "in a drum lane: off, on, accented, and off again."),
              HelpStep("Shape the sound.", "Click a lane's name for its knobs, and the 303's for the bass."),
              HelpStep("Build the song.", "The + at the end of the song strip adds a pattern to it."),
            ])),
          HelpPart(
            "Read the window",
            .terms([
              HelpTerm("Sidebar", "The songs Driftbox comes with. The up and down arrows step through them."),
              HelpTerm(
                "Toolbar",
                "Play, back to the start, where the song is, its tempo and swing, and the clock switches."),
              HelpTerm(
                "Song strip",
                "The song's patterns in order, each as wide as its bars: click one to play from it. The metronome, "
                  + "count-in, automation and any loop sit over it."),
              HelpTerm(
                "Grid",
                "The pattern playing, or the one chosen above it: a lane for each drum voice, then the 303 lines. "
                  + "The lit column is the step playing."),
              HelpTerm(
                "Right", "The knobs of the voice or 303 chosen, the song's effects, and the filter pad."),
            ])),
          HelpPart(
            "Easy to miss",
            .terms([
              HelpTerm(
                "Knobs",
                "Drag up and down; hold Option for fine steps. Double-click puts one back where it started; "
                  + "the arrow keys move one that has focus."),
              HelpTerm("Numbers", "The tempo, the swing and a pattern's steps are dragged up and down too."),
              HelpTerm(
                "Menus",
                "A lane's ··· appears when the pointer is on its name. Right-click a pattern's name, or a "
                  + "section in the song strip, for everything else that can be done to it."),
            ])),
        ]),
      HelpTopic(
        "patterns", "Patterns",
        [
          HelpPart(
            "Patterns and machines",
            .terms([
              HelpTerm(
                "808 and 909",
                "Each lane is one drum voice. + lane adds a voice the pattern is not using yet."),
              HelpTerm(
                "303 A and B", "Two bass synths, a line each. Every step holds a note, an accent and a slide."
              ),
              HelpTerm(
                "Pattern bar",
                "Choose the pattern to edit, or follow to see whichever is playing. + makes a new one; the others "
                  + "duplicate and remove the one chosen. Right-click a name to rename, duplicate, add it to the end "
                  + "of the song, clear or remove it."),
              HelpTerm(
                "Steps", "How long the pattern is, from 1 to 64 steps: drag the number under the lanes."),
            ])),
          HelpPart(
            "Drums",
            .terms([
              HelpTerm("Steps", "A click goes off, on, accented, and round again."),
              HelpTerm(
                "Flam",
                "On the 909, a second strike close behind the first: switch flam on under the lanes and click, "
                  + "or Option-click a step. The slider beside it sets how close."),
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
              HelpTerm(
                "Copy, Cut, Paste", "A lane pastes into any drum lane, and a 303 line into a 303 line."),
            ])),
          HelpPart(
            "303 lines",
            .terms([
              HelpTerm(
                "Notes", "Click a cell to put the note there; click it again to rest it, keeping its pitch."),
              HelpTerm(
                "Accent and slide",
                "Accent strikes the step harder and brighter. Slide holds the note into the next one and glides "
                  + "to it rather than striking it again."),
              HelpTerm(
                "Its menu",
                "Beside the line's name: rotate it, move it by octaves or semitones, randomise or alter it."),
              HelpTerm(
                "Step entry",
                "In the 303's knobs, step entry writes the notes typed on the keys into the stopped pattern, a "
                  + "step at a time."),
            ])),
        ]),
      HelpTopic(
        "song", "Song & automation",
        [
          HelpPart(
            "The song strip",
            .prose([
              "Each block is a section: a pattern, and how many bars it repeats. Click one to play from it. "
                + "Right-click it to change its pattern or how often it repeats, to give one machine another "
                + "pattern's part in it, to move it or to take it out."
            ]),
            note:
              "A pattern is material to use again; a section says what plays, for how long, and in what order."
          ),
          HelpPart(
            "Looping",
            .terms([
              HelpTerm(
                "A section", "Transport ▸ Loop Current Section (⌘L), or Loop This Section from its menu."),
              HelpTerm(
                "Longer", "Stretch Loop to Here, from a later section's menu, takes the loop on to it."),
              HelpTerm("Stopping", "Click the loop's chip over the strip."),
            ])),
          HelpPart(
            "Automation",
            .steps([
              HelpStep("Arm ● auto", "over the song strip, or Transport ▸ Record Automation."),
              HelpStep("Play,", "and turn a knob, or drag the tempo or the swing."),
              HelpStep(
                "Play it again.", "What you turned is in the song, where the song was when you turned it."),
            ]),
            note:
              "● auto counts the lanes recorded. Transport ▸ Clear Automation empties them, and undo brings "
              + "them back."),
          HelpPart(
            "Transport",
            .terms([
              HelpTerm(
                "Tempo and swing",
                "The tempo is the song's. Swing holds back every other sixteenth; each drum voice's own swing says "
                  + "how far it follows."),
              HelpTerm(
                "click and 1·2·3·4", "The metronome, and a bar of count-in before playing from a stop."),
              HelpTerm(
                "sync and clock",
                "Follow a MIDI clock from outside, tempo, start and stop; or send one. Where it goes is in "
                  + "Settings."),
            ])),
        ]),
      HelpTopic(
        "sound", "Sound, MIDI & files",
        [
          HelpPart(
            "Voices and the 303s",
            .terms([
              HelpTerm("A voice", "Click its name for its knobs; hit it plays it."),
              HelpTerm(
                "Out", "Each voice's sends to the delay and the reverb, and its swing against the song's."),
              HelpTerm("A and B", "Switch the 303's knobs between the two lines."),
            ])),
          HelpPart(
            "The song's effects",
            .terms([
              HelpTerm(
                "Drive and Comp", "Drive saturates the whole mix; Comp holds its peaks down and glues it."),
              HelpTerm(
                "Filter",
                "The pattern-controlled filter's cutoff, resonance, envelope and decay. The PCF lane says when it "
                  + "strikes."),
              HelpTerm("Delay and Reverb", "The one echo and the one space every voice's sends feed."),
              HelpTerm("Filter pad", "Drag across it to sweep the filter live; let go and it springs back."),
            ])),
          HelpPart(
            "Keys and MIDI",
            .terms([
              HelpTerm(
                "Typing keys",
                "The home row plays the 303 whose knobs are showing, and the number row strikes the drum voices "
                  + "in the grid's order. Shift accents."),
              HelpTerm(
                "A MIDI keyboard",
                "Notes from A1 up play the 303, the notes below them the drums. Hit hard, a note is accented."
              ),
              HelpTerm(
                "Settings", "Which MIDI to listen to, where the clock goes, and what to play through."),
            ])),
          HelpPart(
            "Files, sound and pictures",
            .terms([
              HelpTerm(
                "Songs",
                "File ▸ Open and Save. A song is a .driftbox file; the web app's songs open as they are."),
              HelpTerm(
                "Export",
                "Mix (⌘E) renders the song mastered; Stems (⇧⌘E) a file per voice, before the master; Movie (⌥⌘E) "
                  + "the song with its visuals."),
              HelpTerm(
                "Record Performance",
                "(⌥⌘R) keeps what you play and turn, and writes it as a movie when you stop."),
              HelpTerm(
                "Visuals",
                "Window ▸ Visuals (⌘2) is a window for a second screen or a projector, full screen from View. "
                  + "Vibes (⇧⌘P) gives this window to the visuals, the whole of it a filter pad."),
              HelpTerm("Rack", "Window ▸ Rack (⌘3) is the modular rack, which has its own guide."),
            ])),
        ]),
      HelpTopic(
        "keys", "Shortcuts",
        [
          HelpPart(
            "Playing",
            .keys([
              HelpKey("Space", "Play or stop"),
              HelpKey("⌘↩", "Back to the start"),
              HelpKey("⌘[  ⌘]", "The previous or the next pattern"),
              HelpKey("⌘L", "Loop the section playing"),
              HelpKey("⌘K  ⇧⌘K", "Metronome, count-in"),
            ])),
          HelpPart(
            "Keys",
            .keys([
              HelpKey("A S D F G H J K", "The 303's minor scale, up from its root, A"),
              HelpKey("W R T U I", "The notes between"),
              HelpKey("Z  X", "An octave down or up"),
              HelpKey("1 … =", "The drum voices, in the grid's order"),
              HelpKey("Shift", "An accent"),
            ])),
          HelpPart(
            "303 step entry",
            .keys([
              HelpKey("A … K", "Write the note and move on"),
              HelpKey("Delete", "Write a rest"),
              HelpKey("Return", "Hold the note before through this step"),
            ]),
            note: "Only while step entry is on and the song is stopped."),
          HelpPart(
            "Windows and files",
            .keys([
              HelpKey("⇧⌘P", "Vibes, and Esc to leave"),
              HelpKey("⌥⌘]", "The next scene"),
              HelpKey("⌘2  ⌘3", "Visuals, Rack"),
              HelpKey("⌘E  ⇧⌘E  ⌥⌘E", "Export the mix, the stems, a movie"),
              HelpKey("⌥⌘R", "Record a performance"),
              HelpKey("⌘?", "This guide"),
            ])),
        ]),
    ])
}
