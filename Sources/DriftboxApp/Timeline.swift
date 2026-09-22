#if canImport(AVFoundation)
  import DriftboxSeq

  /// Where every step of the arrangement starts, at the tempo the song is running at. The
  /// transport, the grid and the scene all ask where the song is, many times a frame; planning the
  /// whole song each time was the main thread's entire day, and the tick never ran.
  struct Timeline {
    /// The start of each step, in seconds; `end` is where the last one finishes.
    var times: [Double] = []
    var bars: [Int] = []
    var indices: [Int] = []
    var end = 0.0

    init() {}

    init(song: Song) {
      var time = 0.0
      for bar in 0..<(song.chain.isEmpty ? 1 : song.bars) {
        for index in 0..<song.barLength(forBar: bar) {
          times.append(time)
          bars.append(bar)
          indices.append(index)
          time += 60 / song.bpm(bar: bar, index: index) / 4
        }
      }
      end = time
    }

    /// The last step that had started by `time`.
    func step(at time: Double) -> Int? {
      var low = 0
      var high = times.count
      while low < high {
        let middle = (low + high) / 2
        if times[middle] <= time { low = middle + 1 } else { high = middle }
      }
      return low == 0 ? nil : low - 1
    }

    /// How long `step` lasts; the last one runs to the end of the pass.
    func length(ofStep step: Int) -> Double {
      let start = times[step]
      return max(0, (step + 1 < times.count ? times[step + 1] : end) - start)
    }

    /// Where `bar` begins; the end of the song for a bar past its last.
    func start(ofBar bar: Int) -> Double {
      bars.firstIndex(of: bar).map { times[$0] } ?? end
    }
  }
#endif
