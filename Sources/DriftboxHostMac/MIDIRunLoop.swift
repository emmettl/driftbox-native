#if canImport(CoreMIDI)
  import DriftboxHost
  import CoreFoundation
  import Foundation

  /// A thread of its own for CoreMIDI clients to be made on.
  ///
  /// CoreMIDI tells a client about devices coming and going on the run loop of the thread that
  /// made the client, and only while that run loop is turning. Measured, not assumed: a client
  /// made on the main thread of an application hears a source appear, and the same client made
  /// on a main thread served by `dispatchMain`, or on a thread that is not running its loop,
  /// hears nothing at all. An application's main thread happens to qualify, which is why that
  /// went unnoticed — but it made every client depend on who made it, and a test runner serves
  /// its main actor through dispatch. So clients are made here, where the loop always turns.
  final class MIDIRunLoop: @unchecked Sendable {
    static let shared = MIDIRunLoop()

    private var loop: CFRunLoop?

    private init() {
      let ready = DispatchSemaphore(value: 0)
      let thread = Thread { [self] in
        loop = CFRunLoopGetCurrent()
        // A run loop with nothing to watch returns at once. A source that is never signalled
        // gives it something to wait on for ever.
        var context = CFRunLoopSourceContext()
        let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)
        CFRunLoopAddSource(loop, keepAlive, .defaultMode)
        ready.signal()
        CFRunLoopRun()
      }
      thread.name = "Driftbox MIDI"
      thread.qualityOfService = .userInteractive
      thread.start()
      ready.wait()
    }

    /// Run `body` on the thread and wait for it.
    func sync<T>(_ body: () -> T) -> T {
      guard let loop, CFRunLoopGetCurrent() !== loop else { return body() }
      return withoutActuallyEscaping(body) { body in
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
          result.value = body()
          done.signal()
        }
        CFRunLoopWakeUp(loop)
        done.wait()
        return result.value as! T
      }
    }

    private final class Result: @unchecked Sendable {
      var value: Any?
    }
  }
#endif
