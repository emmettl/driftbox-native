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
        exporting = Task.detached {
          let audio = SongRenderer.render(song, options: .init(sampleRate: sampleRate))
          try? WAV.data(audio, sampleRate: sampleRate).write(to: url)
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
        exporting = Task.detached {
          for voiceId in SongRenderer.voicesUsed(song) {
            var options = SongRenderer.Options(sampleRate: sampleRate)
            options.only = [voiceId]
            let audio = SongRenderer.render(song, options: options)
            let file = folder.appendingPathComponent("\(name) - \(voiceId).wav")
            try? WAV.data(audio, sampleRate: sampleRate).write(to: file)
          }
        }
      }
    }
  }
}
