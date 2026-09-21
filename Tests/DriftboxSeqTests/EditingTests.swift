import DriftboxSeq
import Testing

struct EditingTests {
  @Test func cyclingAStepGoesOffOnAccentOff() {
    var pattern = Pattern(id: "p", name: "P", length: 8)
    pattern = pattern.cyclingStep("808.bd", at: 3)
    #expect(pattern.step("808.bd", at: 3) == .on)
    #expect(pattern.tracks["808.bd"]?.count == 8)
    pattern = pattern.cyclingStep("808.bd", at: 3)
    #expect(pattern.step("808.bd", at: 3) == .accent)
    pattern = pattern.cyclingStep("808.bd", at: 3)
    #expect(pattern.step("808.bd", at: 3) == .off)
    #expect(pattern.step("808.bd", at: 2) == .off)
  }

  @Test func aStepThatGoesOffLosesItsFlam() {
    var pattern = Pattern(id: "p", name: "P", length: 4)
    pattern = pattern.settingStep("909.sd", at: 1, to: .on)
    pattern.flams["909.sd"] = [false, true, false, false]
    pattern = pattern.settingStep("909.sd", at: 1, to: .off)
    #expect(pattern.flam("909.sd", at: 1) == false)
  }

  @Test func editsRespectAShorterLane() {
    var pattern = Pattern(id: "p", name: "P", length: 16)
    pattern.trackLengths["808.ch"] = 6
    pattern = pattern.settingStep("808.ch", at: 7, to: .on)
    #expect(pattern.step("808.ch", at: 1) == .on)
  }
}

struct BassEditingTests {
  @Test func pausingKeepsThePitchAndSoundingRestoresIt() {
    var step = BassStep(note: 7)
    #expect(step.sounds)
    step = step.settingGate(false)
    #expect(!step.sounds && step.note == 7 && step.gate == false)
    step = step.settingGate(true)
    #expect(step.sounds && step.gate == nil)
    #expect(BassStep.rest.settingGate(true).note == 0)
    #expect(BassStep.rest.settingGate(false) == .rest)
  }

  @Test func slidingABlankRestGivesItASilentRoot() {
    let step = BassStep.rest.settingSlide(true)
    #expect(step.slide && step.note == 0 && step.gate == false && !step.sounds)
    #expect(BassStep(note: 3).settingSlide(true) == BassStep(note: 3, slide: true))
  }

  @Test func settingAStepFillsTheLineWithRests() {
    let pattern = Pattern(id: "p", name: "P", length: 8).settingBassStep(
      "303.a", at: 5, to: BassStep(note: 12))
    #expect(pattern.bass["303.a"]?.count == 8)
    #expect(pattern.bassStep("303.a", at: 5).note == 12)
    #expect(pattern.bassStep("303.a", at: 4) == .rest)
    #expect(pattern.bassStep("303.a", at: 13).note == 12)
  }
}
