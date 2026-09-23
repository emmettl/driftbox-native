#if os(Android)
  import Android
  import DriftboxGPU
  import DriftboxGPUGLES
  import DriftboxHost
  import DriftboxScenes

  /// Every scene on the GPU layer, on the phone's own GPU: each one draws, is not black, and moves
  /// when the music does, as `SurfaceSceneTests` holds them on the other backends, with its input.
  /// Their shaders are compiled here by a phone's OpenGL ES driver, which is not Mesa's; and each is
  /// timed at the size the app draws it for this screen, and at every pixel of the screen, which is
  /// what says whether it keeps up with the display.
  enum SceneCheck {
    static func run(width: Int, height: Int, density: Float) -> String {
      let device: GLESDevice
      do {
        device = try GLESDevice()
      } catch {
        return "FAIL no OpenGL ES device: \(error)"
      }
      let drawn = Renderer.drawn(width: width, height: height, density: density)
      var lines = [
        "on \(device.renderer), timed drawn at \(drawn.width) by \(drawn.height) and at every pixel, "
          + "\(width) by \(height)"
      ]
      for type in GPUScenes.all {
        do {
          let scene = try type.init(device: device)
          let small = try device.makeTarget(width: 160, height: 90)
          var frames: [[UInt8]] = []
          for time in stride(from: 0.0, through: 3, by: 1.0 / 30) {
            scene.draw(playing(at: time), into: small, on: device)
            if [1.0, 3.0].contains(where: { abs($0 - time) < 0.001 }) {
              frames.append(try device.readPixels(small))
            }
          }
          let shade = brightness(frames[1])
          let timing =
            "\(try time(scene, on: device, width: drawn.width, height: drawn.height)) drawn, "
            + "\(try time(scene, on: device, width: width, height: height)) at every pixel"
          if shade > 0.01, frames[0] != frames[1] {
            lines.append("PASS \(type.name) draws, is not black, and moves; \(timing)")
          } else {
            lines.append(
              "FAIL \(type.name): brightness \(shade), \(frames[0] == frames[1] ? "still" : "moving"); \(timing)"
            )
          }
        } catch {
          lines.append("FAIL \(type.name): \(error)")
        }
      }
      return lines.joined(separator: "\n")
    }

    /// How long `scene` takes a frame at `width` by `height`, over sixty of them, in milliseconds.
    static func time(_ scene: any GPUScene, on device: GLESDevice, width: Int, height: Int) throws -> String {
      let target = try device.makeTarget(width: width, height: height)
      _ = try device.readPixels(target)
      let began = HostTime.now()
      for index in 0..<60 { scene.draw(playing(at: 3 + Double(index) / 120), into: target, on: device) }
      // Reading back waits for everything drawn, so the sixty frames are timed whole.
      _ = try device.readPixels(target)
      let tenths = Int((HostTime.seconds(from: began, to: HostTime.now()) / 60 * 10_000).rounded())
      return "\(tenths / 10).\(tenths % 10)ms"
    }

    /// A few seconds of playing, as `SurfaceSceneTests` has it: running, on the beat, the bands up,
    /// a finger down for a while.
    static func playing(at time: Double) -> SceneInput {
      let swell = Float(0.5 + 0.4 * sin(time * 3))
      return SceneInput(
        time: time, touch: time > 1 ? SIMD2(0.3, 0.6) : nil, running: true, bpm: 124,
        scoreBeat: time * 124 / 60, levels: (swell, swell * 0.8, swell * 0.6),
        wideLevels: (swell, swell * 0.5))
    }

    /// The mean of every pixel's red, green and blue, 0...1.
    static func brightness(_ bgra: [UInt8]) -> Double {
      var total = 0
      var at = 0
      while at + 3 < bgra.count {
        total += Int(bgra[at]) + Int(bgra[at + 1]) + Int(bgra[at + 2])
        at += 4
      }
      return Double(total) / Double(bgra.count / 4 * 3 * 255)
    }
  }
#endif
