#if os(Windows)
  import DriftboxHost
  import Synchronization
  import WinSDK

  /// The sources a stream plays, summed, handed between threads without a lock.
  ///
  /// The render thread reads a table of sources through one atomic pointer. Changing what plays
  /// means building a new table on the interface's thread, swapping it in, and freeing the old one
  /// once the render thread has finished a buffer since the swap — it read the old table at the
  /// start of a buffer at the latest, so a buffer ended after the swap is one that no longer can.
  /// The sources outlive any one stream: a change of device makes a new stream over the same mixer.
  final class Mixer: @unchecked Sendable {
    struct Entry {
      var context: UnsafeMutableRawPointer
      var render: RenderSource.Render
    }

    struct Table {
      var count: Int
      var entries: UnsafeMutablePointer<Entry>
    }

    /// The table the render thread reads, by address; 0 for none.
    private let table = Atomic<Int>(0)
    /// Buffers finished by the render thread, which is how a swap knows the old table is done with.
    let buffers = Atomic<Int>(0)
    /// Whether a render thread is running at all. With none, a table swapped out is free at once.
    let rendering = Atomic<Bool>(false)
    /// The sources, and what keeps each alive, on the interface's thread.
    private(set) var sources: [RenderSource] = []

    deinit {
      if let old = Self.table(at: table.exchange(0, ordering: .acquiringAndReleasing)) { Self.free(old) }
    }

    func add(_ source: RenderSource) {
      sources.removeAll { $0.context == source.context }
      sources.append(source)
      publish()
    }

    func remove(_ context: UnsafeMutableRawPointer) {
      sources.removeAll { $0.context == context }
      publish()
    }

    private func publish() {
      let fresh = UnsafeMutablePointer<Table>.allocate(capacity: 1)
      let entries = UnsafeMutablePointer<Entry>.allocate(capacity: max(1, sources.count))
      for (index, source) in sources.enumerated() {
        (entries + index).initialize(to: Entry(context: source.context, render: source.render))
      }
      fresh.initialize(to: Table(count: sources.count, entries: entries))
      let seen = buffers.load(ordering: .acquiring)
      let old = table.exchange(Int(bitPattern: fresh), ordering: .acquiringAndReleasing)
      guard let old = Self.table(at: old) else { return }
      // Two buffers rather than one: a buffer that ends between the swap and the count above
      // being read would otherwise vouch for a table it may have started with.
      var waited = 0
      while rendering.load(ordering: .acquiring), buffers.load(ordering: .acquiring) < seen + 2 {
        Sleep(1)
        waited += 1
        // A device stalled mid-buffer. Leaking the table is the only safe thing left.
        if waited > 500 { return }
      }
      Self.free(old)
    }

    private static func table(at address: Int) -> UnsafeMutablePointer<Table>? {
      UnsafeMutablePointer(bitPattern: address)
    }

    private static func free(_ table: UnsafeMutablePointer<Table>) {
      table.pointee.entries.deallocate()
      table.deallocate()
    }

    /// Every source, summed into `left` and `right`, with `scratch` to render each into. From the
    /// render thread only.
    func render(
      frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
      scratchLeft: UnsafeMutablePointer<Float>, scratchRight: UnsafeMutablePointer<Float>
    ) {
      left.update(repeating: 0, count: frames)
      right.update(repeating: 0, count: frames)
      guard let table = Self.table(at: table.load(ordering: .acquiring)) else { return }
      for index in 0..<table.pointee.count {
        let entry = table.pointee.entries[index]
        entry.render(entry.context, frames, scratchLeft, scratchRight)
        for frame in 0..<frames {
          left[frame] += scratchLeft[frame]
          right[frame] += scratchRight[frame]
        }
      }
    }
  }
#endif
