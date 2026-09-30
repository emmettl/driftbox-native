extension RackHelp {
  static func learningPath(for platform: HelpPlatform) -> HelpTopic {
    let whereTours =
      platform == .android
      ? "Open the patch's menu and choose Rack Tours."
      : "Choose Help ▸ Rack Tours."
    return HelpTopic(
      "learning", "Learning path",
      [
        HelpPart(
          "How to use the tours",
          .prose([
            "\(whereTours) Each tour starts from a small practice patch and checks the steps as you perform them. Take them in the order below, or repeat the one you need.",
            "A tour keeps the patch you had before it. At the end, choose Keep This Patch to continue experimenting, or Back to your previous patch to restore it. Skip moves past a step without doing the work for you; a skipped step can still be completed while the tour is open.",
            "Hide folds the instruction panel to leave more room for the patch; Show opens it again. You can keep playing and editing while the panel is folded.",
          ])),
        HelpPart(
          "1 · A sound of your own · 3 minutes",
          .steps([
            HelpStep(
              "Learn the two sides.",
              "Add a Voice, play notes and turn the rack round to see the automatically added connections. Pitch chooses the note; gate starts it and holds it."
            ),
            HelpStep(
              "Listen for the envelope.",
              "On the front, compare a short note and a held note. Change one Voice knob at a time so you can hear which part of the sound it changes."
            ),
            HelpStep(
              "Try it again.",
              "Release every note and play a different pitch. The keys play an instrument; the rack's transport is for clocks and sequencers and is not required for this exercise."
            ),
          ])),
        HelpPart(
          "2 · Your first cable · 4 minutes",
          .steps([
            HelpStep(
              "Insert a filter.",
              "The practice patch repeats a Voice when the transport runs. Add a Ladder and connect Voice Out → Ladder In, then Ladder Out → Out In."
            ),
            HelpStep(
              "Listen to the path.",
              "Lower Cutoff and hear the bright edge soften. The effect belongs in the path to Out; a filter connected at its input alone cannot change what reaches the speakers."
            ),
            HelpStep(
              "Compare the bypass.",
              "After completing the tour, connect Voice Out straight to Out In. The original brightness returns. Put Ladder Out back into Out In to restore the filtered path."
            ),
          ])),
        HelpPart(
          "3 · Make it move · 4 minutes",
          .steps([
            HelpStep(
              "Add movement.",
              "Send the LFO's Bi output to the Ladder's Cutoff input. Bi moves above and below zero; the Cutoff knob sets the centre of that movement."
            ),
            HelpStep(
              "Separate speed from depth.",
              "Turn Rate for slower or faster sweeps. Turn the trim beside the Cutoff input towards zero for a shallower sweep; these are different changes."
            ),
            HelpStep(
              "Listen at zero.",
              "After the tour, set that trim to zero: the movement stops even though the LFO is still running. Raise it a little to bring back a gentle sweep."
            ),
          ])),
        HelpPart(
          "4 · Let it play itself · 5 minutes",
          .steps([
            HelpStep(
              "Make a repeating phrase.",
              "Connect Transport 1/16 → Seq Clock, Seq Pitch → Voice V/Oct and Seq Gate → Voice Gate. Start the rack's transport."
            ),
            HelpStep(
              "Give it rhythm.",
              "Set a few pitch knobs and switch some Seq steps off. Listen for the gaps as well as the notes."
            ),
            HelpStep(
              "Diagnose one missing cable.",
              "After the tour, remove the Seq's Gate cable. Pitch alone does not trigger the Voice. Reconnect Gate and the phrase returns."
            ),
          ])),
        HelpPart(
          "5 · Four knobs that play the patch · 4 minutes",
          .steps([
            HelpStep(
              "Bring useful controls together.",
              "Add a Combinator and open Routing…. Route Rotary 1 to the Ladder's Cutoff, with endpoints 300 and 2400, and Rotary 2 to the Voice's Release, from 0.08 to 0.6 seconds."
            ),
            HelpStep(
              "Listen to each separately.",
              "Start the repeating patch. Rotary 1 changes brightness; Rotary 2 changes how long notes linger after the gate ends."
            ),
            HelpStep(
              "Make a playable range.",
              "Adjust the routing endpoints until both extremes are useful. A smaller range is often easier to perform with than the target knob's entire range."
            ),
          ])),
        HelpPart(
          "When a step will not tick",
          .terms([
            HelpTerm(
              "Read the named jacks",
              "A cable to the wrong control input can still be a valid cable. Check both module names and both port names, especially Pitch versus Gate and Bi versus Uni."
            ),
            HelpTerm(
              "Check the sound path",
              "Some steps need a complete path to Out or running transport as well as a cable. Follow the current instruction before adding more modules."
            ),
            HelpTerm(
              "A step completed early",
              "The tour checks all its steps, so an action performed early may already be ticked. Continue with the first unfinished instruction."
            ),
            HelpTerm(
              "Start again",
              "End the tour, restore your previous patch if offered, and select the tour again for a fresh practice patch. Use a module's Guide for its controls and signal flow, or the Silence topic to trace a quiet patch."
            ),
          ])),
      ])
  }
}
