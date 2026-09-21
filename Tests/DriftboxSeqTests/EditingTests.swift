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
