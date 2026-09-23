/// Where every step of the arrangement starts, at the tempo the song is running at. The
/// transport, the grid and the scene all ask where the song is, many times a frame; planning the
/// whole song each time was the main thread's entire day, and the tick never ran.
public struct Timeline {
  /// The start of each step, in seconds; `end` is where the last one finishes.
  public var times: [Double] = []
  public var bars: [Int] = []
  public var indices: [Int] = []
  public var end = 0.0

  public init() {}

  public init(song: Song) {
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
  public func step(at time: Double) -> Int? {
    var low = 0
    var high = times.count
    while low < high {
      let middle = (low + high) / 2
      if times[middle] <= time { low = middle + 1 } else { high = middle }
    }
    return low == 0 ? nil : low - 1
  }

  /// How long `step` lasts; the last one runs to the end of the pass.
  public func length(ofStep step: Int) -> Double {
    let start = times[step]
    return max(0, (step + 1 < times.count ? times[step + 1] : end) - start)
  }

  /// Where `bar` begins; the end of the song for a bar past its last.
  public func start(ofBar bar: Int) -> Double {
    bars.firstIndex(of: bar).map { times[$0] } ?? end
  }

  /// Where the song is at `time`, in quarter notes from the top: the steps so far and the part
  /// of the one sounding, so a scene reading it moves smoothly between steps. Nil for a song
  /// with no steps.
  public func scoreBeat(at time: Double) -> Double? {
    guard !times.isEmpty else { return nil }
    guard let index = step(at: time) else { return 0 }
    let start = times[index]
    let end = index + 1 < times.count ? times[index + 1] : end
    let fraction = end > start ? min(1, (time - start) / (end - start)) : 0
    return (Double(index) + fraction) / 4
  }
}
