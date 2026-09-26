import DriftboxGPU
import DriftboxMovie
import DriftboxSession
import DriftboxShell
import DriftboxText
import Foundation

/// Movies, as the Mac's File menu makes them: the song and its visuals from the top, or a
/// performance recorded as it was played, each written while the app carries on — how far it has
/// got in the title — then shown where it was put.
extension Desktop {
  static let movie = FileType(name: "MPEG-4 Movie", extensions: ["mp4"])

  /// A movie written in a format, on a GPU with a typesetter, through a writer, telling how far.
  typealias MovieWriting =
    @MainActor (
      MovieFormat, any GPUDevice, any Typesetter, any MovieWriter, (Double) -> Bool
    ) async throws -> Void

  /// The song and its visuals, seen as the scene chosen or the song's own, where the person says.
  func exportMovie() {
    guard let song = session.song, movieProgress == nil else { return }
    let scene = chosenScene
    documentRequest { done in
      window.chooseSaveLocation(for: Self.movie, name: session.documentName) { [self] url in
        defer { done() }
        guard let url else { return }
        writeMovie(to: url) { format, device, typesetter, writer, progress in
          try await Movie.write(
            song, scene: scene, format: format, device: device, typesetter: typesetter, to: writer,
            progress: progress)
        }
      }
    }
  }

  /// Record what is played from now, starting with the scene showing; or stop, and write it.
  func toggleRecording() {
    if session.isRecording {
      stopRecording()
    } else if movieProgress == nil {
      session.startRecording(scene: chosenScene)
    }
  }

  /// Stop recording and ask where its movie goes. Cancelled, the take goes with it: it is a
  /// performance, and there is no other copy of it.
  func stopRecording() {
    guard let take = session.stopRecording() else { return }
    documentRequest { done in
      window.chooseSaveLocation(for: Self.movie, name: "\(session.documentName) Performance") { [self] url in
        defer { done() }
        guard let url else { return }
        writeMovie(to: url) { format, device, typesetter, writer, progress in
          try await Movie.write(
            take, format: format, device: device, typesetter: typesetter, to: writer, progress: progress)
        }
      }
    }
  }

  /// The movie being written, stopped at its next frame, and taken away.
  func stopMovie() { movieStopped = true }

  /// One movie at a time, on this window's GPU, then shown where it was put; one that fails says why.
  private func writeMovie(to url: URL, _ write: @escaping MovieWriting) {
    movieProgress = 0
    movieStopped = false
    let format = movieFormat
    movie = Task { [weak self] in
      guard let self else { return }
      do {
        let writer = try makeMovieWriter(url, format)
        try await write(format, device, typesetter, writer) { [weak self] done in
          guard let self else { return false }
          movieProgress = done
          return !movieStopped
        }
        window.reveal(url)
      } catch is CancellationError {
      } catch {
        window.tell("The movie could not be written. \(error)")
      }
      movieProgress = nil
    }
  }

  /// What the platform writes movies with: Media Foundation on Windows.
  static func movieWriter(_ url: URL, _ format: MovieFormat) throws -> any MovieWriter {
    #if os(Windows)
      return try MediaFoundationMovie(url: url, format: format)
    #else
      throw MovieFailure.writer("there is nothing to write movies with here yet")
    #endif
  }

  /// What the title says is going on: a movie being written, and how far, or a performance being
  /// recorded, and for how long.
  var activity: String? {
    if let movieProgress { return "Writing Movie \(Int(movieProgress * 100))%" }
    guard session.isRecording else { return nil }
    let seconds = Int(session.recordingSeconds)
    return "Recording \(seconds / 60):" + (seconds % 60 < 10 ? "0" : "") + "\(seconds % 60)"
  }
}
