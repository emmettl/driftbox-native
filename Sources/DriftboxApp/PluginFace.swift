#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxSeq
  import DriftboxSession
  import SwiftUI

  /// The groovebox as it shows inside another app, as an Audio Unit's face: the window's editor
  /// with the visuals behind it, under a bar that does what the window's toolbar and song list do —
  /// the song, the transport, the tempo — since an app's window has neither to lend it.
  public struct GrooveboxPluginFace: View {
    let player: Session
    let stage: Stage
    /// Open one of the catalogue's songs, as the app's own preset menu does.
    let open: (Int) -> Void

    public init(player: Session, stage: Stage, open: @escaping (Int) -> Void) {
      self.player = player
      self.stage = stage
      self.open = open
    }

    public var body: some View {
      ZStack {
        Backdrop(stage: stage, running: player.showsVisuals)
        VStack(spacing: 12) {
          bar
          if let song = player.song {
            SongEditor(player: player, song: song)
          } else {
            Spacer()
          }
        }
        .padding(14)
      }
      .frame(minWidth: 820, minHeight: 560)
      .preferredColorScheme(.dark)
      .tint(Theme.nine)
    }

    private var bar: some View {
      HStack(spacing: 10) {
        Menu {
          ForEach(Array(player.entries.enumerated()), id: \.element.id) { number, entry in
            Button(entry.name) { open(number) }
          }
        } label: {
          Text(player.documentName).font(Theme.mono(13, .semibold)).foregroundStyle(Theme.ink)
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Open one of the songs Driftbox comes with")
        PlayButton(player: player)
        Button {
          player.seek(toStep: 0)
        } label: {
          Label("Return to Start", systemImage: "backward.end.fill").labelStyle(.iconOnly)
        }
        .help("Return to the start of the song")
        .disabled(player.song == nil)
        Spacer(minLength: 0)
        TransportDisplay(player: player, clocks: false)
        Spacer(minLength: 0)
        Toggle(isOn: Bindable(player).showsVisuals) {
          Label(
            "Visuals",
            systemImage: player.showsVisuals ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack"
          )
          .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .help(
          player.showsVisuals ? "Stop the visuals behind the editor" : "Run the visuals behind the editor")
      }
      .buttonStyle(.bordered)
    }
  }
#endif
