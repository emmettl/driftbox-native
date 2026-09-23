import DriftboxHost
import DriftboxSeq
import Testing

/// The wire's rules, as Android's packets arrive under them.
struct MIDIByteStreamTests {
  func messages(_ packets: [UInt8]...) -> [[UInt8]] {
    var stream = MIDIByteStream()
    var out: [[UInt8]] = []
    for packet in packets { stream.feed(packet) { out.append($0) } }
    return out
  }

  @Test func wholeMessagesComeOutWhole() {
    #expect(
      messages([0x90, 60, 100, 0xB0, 1, 64, 0xC2, 5]) == [[0x90, 60, 100], [0xB0, 1, 64], [0xC2, 5]])
  }

  @Test func runningStatusIsFilledIn() {
    #expect(messages([0x90, 60, 100, 62, 90, 60, 0]) == [[0x90, 60, 100], [0x90, 62, 90], [0x90, 60, 0]])
    #expect(messages([0xD0, 10, 20, 30]) == [[0xD0, 10], [0xD0, 20], [0xD0, 30]])
  }

  @Test func aMessageSplitAcrossPacketsIsJoined() {
    #expect(messages([0x90, 60], [100, 62], [90]) == [[0x90, 60, 100], [0x90, 62, 90]])
  }

  @Test func realTimeComesOutAtOnceWithoutBreakingAMessage() {
    #expect(
      messages([0x90, 0xF8, 60, 0xFA, 100, 62, 90]) == [[0xF8], [0xFA], [0x90, 60, 100], [0x90, 62, 90]])
  }

  @Test func songPositionIsWholeAndDoesNotRun() {
    #expect(messages([0xF2, 0x10, 0x02, 0x20]) == [[0xF2, 0x10, 0x02]])
    #expect(ClockMessage(bytes: messages([0xF2, 0x10, 0x02])[0]) == .position(step: 0x110))
  }

  @Test func systemCommonEndsRunningStatus() {
    #expect(messages([0x90, 60, 100, 0xF6, 62, 90]) == [[0x90, 60, 100], [0xF6]])
  }

  @Test func systemExclusiveIsSkipped() {
    #expect(messages([0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7, 0x80, 60, 0]) == [[0x80, 60, 0]])
    // Ended by the next status rather than its own end, as some devices do.
    #expect(messages([0xF0, 0x41, 0x10, 0x90, 60, 100]) == [[0x90, 60, 100]])
    #expect(messages([0xF0, 0x41], [0x10, 0xF8, 0x42], [0xF7]) == [[0xF8]])
  }

  @Test func dataWithNothingToBelongToIsDropped() {
    #expect(messages([60, 100, 0x90, 60, 100]) == [[0x90, 60, 100]])
  }
}
