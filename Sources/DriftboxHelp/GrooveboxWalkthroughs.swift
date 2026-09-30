extension GrooveboxHelp {
  /// Short listening exercises alongside the control reference. These do not change the song;
  /// the reader performs each edit, using the controls available on their platform.
  static func walkthroughs(for platform: HelpPlatform) -> HelpTopic {
    let touch = platform == .android
    let choose = touch ? "Tap" : "Click"
    let patternMenu = touch ? "Hold a finger on a pattern's chip" : "Right-click a pattern's name"
    let sectionMenu = touch ? "Hold a finger on a song section" : "Right-click a song section"
    let save = touch ? "Open the song's menu from its chip and choose Save As…" : "Choose File ▸ Save As…"
    let loop = platform == .mac ? "Transport ▸ Loop Current Section" : "LOOP in the top bar"
    let addToSong = platform == .mac ? "Add to End of Song" : "Add to Song"
    let auto = platform == .mac ? "● auto above the song strip" : "AUTO in the top bar"
    return HelpTopic(
      "walkthroughs", "Walkthroughs",
      [
        HelpPart(
          "Before you start",
          .prose([
            "These exercises build on one another: a drum variation, a bass phrase, two sections, then a recorded filter sweep. Allow about fifteen minutes and change one thing at a time.",
            "Start with a catalogue song you like. \(save), give your working copy a new name, and save again after each exercise. The steps below edit that copy.",
          ])),
        HelpPart(
          "1 · Make a drum variation",
          .steps([
            HelpStep(
              "Choose one section.",
              "\(choose) it in the song strip and use \(loop) so you hear the same material each time. Select its pattern for editing."
            ),
            HelpStep(
              "Make a working pattern.",
              "\(patternMenu) and choose Duplicate. \(sectionMenu) and choose the duplicate as its pattern; otherwise you will still hear the original."
            ),
            HelpStep(
              "Set a steady pulse.",
              "In a bass-drum lane, turn the first step of each beat on: 1, 5, 9 and 13 in a sixteen-step pattern. A step cycles off, on, accented, then off again; leave these four on and take the other hits out of this lane."
            ),
            HelpStep(
              "Leave space between the beats.",
              "In a closed hi-hat lane, try steps 3, 7, 11 and 15. Keep the other lanes as they are for now."),
            HelpStep(
              "Change the emphasis.",
              "Accent just one of those hi-hat hits. Listen for a stronger hit rather than an extra one, then move the accent to a different beat."
            ),
          ]),
          note: touch
            ? "On a phone, 1–8 and 9–16 show the two halves of the bar. If the chosen pattern has a different length, use its existing beat groups or choose a sixteen-step pattern for this exercise."
            : "The first hit should land with the start of each beat. If the chosen pattern has a different length, use its existing beat groups or choose a sixteen-step pattern for this exercise."
        ),
        HelpPart(
          "2 · Give the bass a phrase",
          .steps([
            HelpStep(
              "Choose 303 A.",
              "Keep the drum loop running and select the 303 line. Use its lane menu to Clear the line if you want to begin with rests."
            ),
            HelpStep(
              "Put in a few notes.",
              touch
                ? "Tap a step to open the step keyboard, then a key to set its note. The keyboard advances after a note; use ◀ and ▶ to choose the next step you want, and REST to leave a gap."
                : "Place notes on steps 1, 4, 7 and 11 by choosing pitch cells in the 303 grid. Keep two at the same pitch and move the others a few semitones above it."
            ),
            HelpStep(
              "Compare an accent.",
              touch
                ? "Return to one of the sounding steps with ◀ or ▶ and turn ACCENT on. Listen for the stronger, brighter attack, then turn it off to compare."
                : "Turn on the accent for one sounding step. Listen for the stronger, brighter attack, then turn it off to compare."
            ),
            HelpStep(
              "Join two notes.",
              touch
                ? "Put notes of different pitches on neighbouring steps. Return to the first of the pair and turn SLIDE on: it leads into the next note without a fresh attack."
                : "Put notes of different pitches on neighbouring steps and enable slide on the first. It leads into the next note without a fresh attack."
            ),
            HelpStep(
              "Shape the phrase.",
              "Select the 303's knobs and slowly lower Cutoff, then bring it back up. Leave some rests: they give the filter and the rhythm room to speak."
            ),
          ]),
          note:
            "If the line changes on screen but not in your ears, check the playing section's pattern and any separate pattern assigned to 303 A in that section."
        ),
        HelpPart(
          "3 · Turn the loop into two sections",
          .steps([
            HelpStep(
              "Keep a simple version.",
              "\(patternMenu) and Duplicate your working pattern again. Give the two patterns different names, such as Main and Fill."
            ),
            HelpStep(
              "Change only the fill.",
              "In Fill, add a drum hit near the end or remove the last bass note. The small difference makes the section change easy to hear."
            ),
            HelpStep(
              "Arrange them.",
              "Use \(addToSong) from each pattern's menu. In the new sections' menus, set Main to repeat four bars and Fill one bar. Remove any unwanted sections from this working copy's song strip."
            ),
            HelpStep(
              "Hear the change.",
              "Clear the loop, return to the beginning and play. Main should repeat four times before the one-bar Fill. Save when the transition sounds right."
            ),
          ]),
          note:
            "Two sections using the same pattern share its edits. Duplicate the pattern when you want a variation; adding another section alone does not make a separate copy."
        ),
        HelpPart(
          "4 · Record a filter sweep",
          .steps([
            HelpStep(
              "Start at the beginning.",
              "Stop playback and return to the start. Select the 303's knobs and choose a comfortably open Cutoff."
            ),
            HelpStep(
              "Arm recording.",
              "Turn on \(auto), then play. Over the first few bars, lower the 303's Cutoff slowly and bring it back up."
            ),
            HelpStep(
              "Disarm and replay.",
              "Stop, turn \(auto) off, return to the start and play again without touching the knob. Listen for the sweep at the same place in the song."
            ),
            HelpStep(
              "Keep a version.",
              "Save the song. Try a shorter sweep next time, or record another control after you are happy with the first."
            ),
          ]),
          note: touch
            ? "Recording this exercise needs a tablet layout with AUTO visible. A phone can play a song's automation but has no AUTO control to record it."
            : "Automation belongs to positions in the song. Leave recording off while comparing takes, so another knob movement does not write over your work."
        ),
      ])
  }

  static func troubleshooting(for platform: HelpPlatform) -> HelpTopic {
    let output: String =
      switch platform {
      case .mac: "Check the output device in Settings and the Mac's output volume."
      case .windows: "Choose the output device in the Audio menu and check the system's output volume."
      case .android:
        "Check Output in the song's menu and the phone's media volume. Another app or a call may have paused playback."
      }
    return HelpTopic(
      "troubleshooting", "Troubleshooting",
      [
        HelpPart(
          "No sound",
          .steps([
            HelpStep(
              "Check that the song is moving.",
              "Start playback and watch the lit step. If external clock sync is on, the song may be waiting for the other device to start."
            ),
            HelpStep(
              "Try a known song.",
              "Save your work, then open a catalogue song. If that plays, return to your working copy and check for sounding notes, voice levels and a closed filter."
            ),
            HelpStep("Check where it goes.", output),
          ])),
        HelpPart(
          "The edit is not what I hear",
          .terms([
            HelpTerm(
              "Editing another pattern",
              "Following playback and choosing a pattern to edit are different. Check the pattern assigned to the playing section, including the separate assignments for each machine."
            ),
            HelpTerm(
              "A section never arrives",
              "A loop may still be active. Clear it to hear the song continue through its arrangement."),
            HelpTerm(
              "A knob keeps changing",
              "Recorded automation can set it again as the song passes that position. Disarm recording before experimenting; clearing automation removes all recorded lanes, so save a copy first."
            ),
            HelpTerm(
              "A rhythm repeats too soon",
              "A lane may have a shorter loop length than its pattern. Check the lane's Loop Length before adding more hits."
            ),
          ])),
        HelpPart(
          "Recover and compare",
          .notes([
            platform == .android
              ? "Undo and Redo are in the song's menu. Undo names the edit it will take back."
              : "Use Edit ▸ Undo to take back the last edit, and Redo to compare it again.",
            "Save As makes a separate song file for experiments. Duplicating a pattern protects that pattern's notes, but song-wide effects and automation still belong to the same song.",
            "When asking for help, keep the song file and note the platform, output device and the smallest sequence of actions that reproduces the problem.",
          ])),
      ])
  }
}
