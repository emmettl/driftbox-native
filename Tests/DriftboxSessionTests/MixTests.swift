import DriftboxSession
import Foundation
import Testing

/// What the scenes read of the mix through the session: the scope's line and the spectrum.
@MainActor
struct MixTests {
  /// The scope's line is the mix: moving while the song plays.
  @Test func theScopeReadsTheMix() throws {
    try withTemporaryDirectory { directory in
      let (session, host) = try openedSession(steadySong(), in: directory)
      renderAudio(host, frames: 4800)
      let samples = session.recentMix(512)
      #expect(samples.count == 512)
      #expect(samples.contains { abs($0) > 0.01 })
    }
  }

  /// Web Audio answers two reads inside one render quantum with the same spectrum, and the
  /// smoothing is applied per analysis. Asking twice before any new audio has arrived must not
  /// smooth twice, or the bands fall faster than they do on the web — which is what a display
  /// faster than the audio blocks, or two views in one frame, would otherwise do.
  @Test func theSpectrumOnlyMovesWhenTheAudioDoes() throws {
    try withTemporaryDirectory { directory in
      let (session, host) = try openedSession(steadySong(), in: directory)
      renderAudio(host, frames: 4800)
      let first = session.analyse().bands(8)
      #expect(first.contains { $0 > 0 }, "a kick every step is something to see")
      let again = session.analyse().bands(8)
      #expect(again == first)

      session.stop()
      renderAudio(host, frames: 48000)
      let later = session.analyse().bands(8)
      #expect(later != first)
    }
  }
}
