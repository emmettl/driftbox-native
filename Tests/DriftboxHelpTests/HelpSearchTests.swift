import DriftboxHelp
import Testing

struct HelpSearchTests {
  let guide = HelpGuide(
    title: "Guide",
    topics: [
      HelpTopic(
        "sound", "Sound",
        [
          HelpPart(
            "Connections", .steps([HelpStep("Connect the gate", "to the Voice.")]), note: "Try a held note."),
          HelpPart("Knobs", .terms([HelpTerm("Cutoff", "Changes brightness.")])),
        ]),
      HelpTopic(
        "keys", "Playing",
        [
          HelpPart("Transport", .keys([HelpKey("Space", "Play or stop")])),
          HelpPart("Remember", .notes(["Save the patch."])),
          HelpPart("Overview", .prose(["The cables carry signals."])),
        ]),
    ])

  @Test func searchesCompletePartsAndKeepsTheirIdentity() {
    #expect(guide.matching("  GATE  voice\n").map(\.id) == ["sound"])
    #expect(guide.matching("gate").first?.parts == [guide.topics[0].parts[0]])
    #expect(guide.matching("held note").first?.parts.first?.heading == "Connections")
    #expect(guide.matching("cutoff brightness").first?.parts.first?.heading == "Knobs")
    #expect(guide.matching("Space stop").first?.id == "keys")
    #expect(guide.matching("save patch").first?.parts.first?.heading == "Remember")
    #expect(guide.matching("signals").first?.parts.first?.heading == "Overview")
    #expect(guide.matching("sound").first?.parts == guide.topics[0].parts)
    #expect(guide.matching("gate brightness").isEmpty, "words cannot match unrelated sections")
  }

  @Test func clearingSearchRestoresTheGuide() {
    #expect(guide.matching(" \n\t") == guide.topics)
    #expect(guide.matching("unfindable").isEmpty)
    #expect(guide.matching("") == guide.topics)
  }
}
