#if os(Android)
  import Android
  import CLooper

  @_silgen_name("_dispatch_get_main_queue_handle_4CF")
  private func dispatchMainQueueHandle() -> Int32

  @_silgen_name("_dispatch_main_queue_callback_4CF")
  private func dispatchMainQueueCallback(_ message: UnsafeMutableRawPointer?)

  /// Swift's main queue, drained by the Android looper of the app's main thread.
  ///
  /// The main actor runs its work on libdispatch's main queue, which something has to drain: on a
  /// Mac the run loop does, and on Linux Foundation's. On Android the main thread is Java's, and its
  /// looper knows nothing of it, so a `Task` on the main actor — a sample loading into the rack —
  /// was queued and never run. libdispatch signals its main queue's work through a file descriptor,
  /// as it does for CoreFoundation's run loop; given to the looper, the looper calls back whenever
  /// there is work, and the callback drains it, on the main thread, between Java's own messages.
  public enum MainQueue {
    nonisolated(unsafe) private static var draining = false

    /// Drain the main queue from the looper of the thread this is called on, which must be the main
    /// thread. Once; true once it is.
    @discardableResult
    public static func drainOnLooper() -> Bool {
      guard !draining else { return true }
      guard let looper = ALooper_forThread() else { return false }
      let handle = dispatchMainQueueHandle()
      guard handle >= 0 else { return false }
      let added = ALooper_addFd(
        looper, handle, Int32(ALOOPER_POLL_CALLBACK), Int32(ALOOPER_EVENT_INPUT),
        { handle, _, _ in
          // The signal read, then the work done: a signal left unread would call back forever.
          var value: eventfd_t = 0
          _ = eventfd_read(handle, &value)
          dispatchMainQueueCallback(nil)
          return 1
        }, nil)
      draining = added == 1
      return draining
    }
  }
#endif
