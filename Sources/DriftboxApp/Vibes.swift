#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(Metal)
  import DriftboxScenes
  import DriftboxSession
  import SwiftUI

  /// Which scene the visuals show: the song's own, or any of them.
  struct SceneMenu: View {
    let player: Session
    let stage: Stage

    var body: some View {
      Menu("Scene") {
        let own = player.song?.visual.map { id in Scenes.all.first { $0.id == id }?.name ?? id }
        Toggle(
          own.map { "The Song's Own (\($0))" } ?? "The Song's Own",
          isOn: Binding(get: { stage.sceneChoice == nil }, set: { if $0 { stage.sceneChoice = nil } }))
        Divider()
        ForEach(Scenes.all.map { (id: $0.id, name: $0.name) }, id: \.id) { scene in
          Toggle(
            scene.name,
            isOn: Binding(
              get: { stage.sceneChoice == scene.id }, set: { if $0 { stage.sceneChoice = scene.id } }))
        }
        Divider()
        Button("Next Scene") { stage.cycleScene() }
          .keyboardShortcut("]", modifiers: [.command, .option])
      }
    }
  }

  extension Stage {
    /// On to the next scene in the list, from whichever is showing.
    func cycleScene(by step: Int = 1) {
      let all = Scenes.all.map { $0.id }
      let at = all.firstIndex(of: sceneId ?? "") ?? -1
      sceneChoice = all[((at + step) % all.count + all.count) % all.count]
    }

    var sceneName: String {
      Scenes.all.first { $0.id == sceneId }?.name ?? Scenes.fallback.name
    }
  }

  /// The window given over to the visuals: a pad the size of the window, what is playing, a
  /// scope, and a way to play, change the scene and get back to the editor. As the web's vibes
  /// mode, and for the same use — standing in front of it rather than editing at it.
  struct VibesStage: View {
    let player: Session
    let stage: Stage
    @State private var touching = false

    var body: some View {
      ZStack {
        // The pad, under everything: a finger anywhere is the filter. The scene draws where it is.
        GeometryReader { geometry in
          Color.clear
            .contentShape(Rectangle())
            .gesture(
              DragGesture(minimumDistance: 0)
                .onChanged { value in
                  touching = true
                  let x = max(0, min(1, value.location.x / geometry.size.width))
                  let y = max(0, min(1, 1 - value.location.y / geometry.size.height))
                  player.pad(x: x, y: y)
                }
                .onEnded { _ in
                  touching = false
                  player.padRelease()
                })
        }
        VStack(spacing: 10) {
          Spacer()
          ScopeView(player: player)
            .frame(width: 420, height: 90)
            .allowsHitTesting(false)
          VStack(spacing: 3) {
            Text(player.documentName.uppercased())
              .font(Theme.mono(18, .bold)).tracking(4).foregroundStyle(Theme.ink)
              .shadow(color: .black.opacity(0.6), radius: 8)
            Text(player.position.map { "\($0.pattern?.name ?? "") · bar \($0.bar + 1)" } ?? "")
              .font(Theme.mono(11)).foregroundStyle(Theme.dim)
            Text(touching ? "" : "drag anywhere to filter")
              .font(Theme.mono(10)).foregroundStyle(Theme.dim.opacity(0.7))
          }
          .allowsHitTesting(false)
          .padding(.bottom, 24)
          HStack(alignment: .bottom) {
            Button {
              player.toggle()
            } label: {
              Image(systemName: player.isPlaying ? "stop.fill" : "play.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(player.isPlaying ? Theme.nine : Theme.ink)
                .frame(width: 64, height: 64)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(player.isPlaying ? Theme.nine : Theme.edge, lineWidth: 1.5))
                .shadow(color: player.isPlaying ? Theme.nine.opacity(0.6) : .clear, radius: 14)
                .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(StepPress())
            .help(player.isPlaying ? "Stop (Space)" : "Play (Space)")
            Spacer()
            HStack(spacing: 8) {
              Button(stage.sceneName) { stage.cycleScene() }
                .buttonStyle(.chip)
                .help("The next scene (⌥⌘])")
              Button {
                stage.performing = false
              } label: {
                Label("edit", systemImage: "square.grid.3x3").labelStyle(.titleAndIcon)
              }
              .buttonStyle(.chip)
              .help("Back to the editor (Esc)")
            }
          }
          .padding(24)
        }
      }
      .onExitCommand { stage.performing = false }
    }
  }

  /// The mix as a line, redrawn with the player's own tick — thirty times a second while the song
  /// moves, which is as often as there is new audio to show.
  struct ScopeView: View {
    let player: Session

    var body: some View {
      // Read so the view is redrawn whenever the transport moves on.
      let moment = player.songFrame
      Canvas { context, size in
        _ = moment
        let samples = player.recentMix(512)
        guard samples.count > 1 else { return }
        var line = Path()
        for (index, sample) in samples.enumerated() {
          let x = size.width * Double(index) / Double(samples.count - 1)
          let y = size.height / 2 - Double(max(-1, min(1, sample))) * size.height / 2
          if index == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.addFilter(.shadow(color: Theme.nine.opacity(0.8), radius: 6))
        context.stroke(line, with: .color(Theme.nine), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
      }
    }
  }
#endif
