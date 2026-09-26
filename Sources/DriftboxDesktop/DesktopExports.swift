import DriftboxDocument
import DriftboxEngine
import DriftboxShell
import Foundation

/// The song as audio, as the Mac's File menu writes it: the mix as one WAV, or each voice it uses as
/// a WAV of its own, rendered off the main thread while the app carries on.
extension Desktop {
  static let wav = FileType(name: "WAV Audio", extensions: ["wav"])

  /// The whole song, mixed, where the person says.
  func exportMix() {
    guard let song = session.song else { return }
    let sampleRate = session.sampleRate
    documentRequest { done in
      window.chooseSaveLocation(for: Self.wav, name: session.documentName) { [self] url in
        defer { done() }
        guard let url else { return }
        exporting = Task.detached { [weak self] in
          let audio = SongRenderer.render(song, options: .init(sampleRate: sampleRate))
          do {
            try WAV.data(audio, sampleRate: sampleRate).write(to: url, options: .atomic)
          } catch {
            await self?.reportAudioExportFailure(
              "Could not export \(url.lastPathComponent): \(error.localizedDescription)")
          }
        }
      }
    }
  }

  /// Each voice the song uses on its own, `<song> - <voice>.wav`, in the folder the person chooses.
  func exportStems() {
    guard let song = session.song else { return }
    let sampleRate = session.sampleRate
    let name = session.documentName
    documentRequest { done in
      window.chooseFolder(title: "Export Stems", button: "Export Here") { [self] folder in
        defer { done() }
        guard let folder else { return }
        exporting = Task.detached { [weak self] in
          var written = 0
          for voiceId in SongRenderer.voicesUsed(song) {
            var options = SongRenderer.Options(sampleRate: sampleRate)
            options.only = [voiceId]
            let audio = SongRenderer.render(song, options: options)
            let file = folder.appendingPathComponent("\(name) - \(voiceId).wav")
            do {
              try WAV.data(audio, sampleRate: sampleRate).write(to: file, options: .atomic)
              written += 1
            } catch {
              let partial =
                written == 0
                ? ""
                : written == 1
                  ? " 1 stem was already exported." : " \(written) stems were already exported."
              await self?.reportAudioExportFailure(
                "Could not export \(file.lastPathComponent): \(error.localizedDescription)\(partial)")
              return
            }
          }
        }
      }
    }
  }
  /// Export workers return to the main actor before asking the native shell to say what failed.
  private func reportAudioExportFailure(_ message: String) { window.tell(message) }
}
