import DriftboxHost
import Testing

/// What every platform's scheduler waits on: the timing is theirs to test, the order is this.
struct MIDIQueueTests {
  @Test func messagesComeOutInTheOrderOfTheirStamps() {
    var queue = MIDIQueue<Int>()
    for (message, time) in [(0, 30), (1, 10), (2, 50), (3, 20), (4, 40)] {
      queue.add(message, to: "out", at: UInt64(time))
    }
    #expect(queue.next == 10)
    #expect(queue.takeDue(at: 100).map(\.message) == [1, 3, 0, 4, 2])
    #expect(queue.next == nil)
  }

  @Test func messagesForTheSameMomentKeepTheirOrder() {
    var queue = MIDIQueue<Int>()
    for message in 0..<5 { queue.add(message, to: "out", at: 10) }
    #expect(queue.takeDue(at: 10).map(\.message) == [0, 1, 2, 3, 4])
  }

  @Test func onlyWhatIsDueIsTaken() {
    var queue = MIDIQueue<Int>()
    queue.add(0, to: "out", at: 10)
    queue.add(1, to: "out", at: 20)
    #expect(queue.takeDue(at: 9).isEmpty)
    #expect(queue.takeDue(at: 10).map(\.message) == [0])
    #expect(queue.next == 20)
  }

  @Test func aDropForgetsOneDestinationOnly() {
    var queue = MIDIQueue<Int>()
    queue.add(0, to: "a", at: 10)
    queue.add(1, to: "b", at: 20)
    queue.add(2, to: "a", at: 30)
    queue.drop("a")
    #expect(queue.takeDue(at: 100).map(\.destination) == ["b"])
  }
}
