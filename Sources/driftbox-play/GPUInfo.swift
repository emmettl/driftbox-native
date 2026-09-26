#if os(Linux)
  import DriftboxGPU
  import DriftboxGPUGLES

  /// Exercise the actual GLES backend before a Linux window is available. Run with
  /// EGL_PLATFORM=surfaceless for SSH/CI; LIBGL_ALWAYS_SOFTWARE=1 deliberately chooses Mesa software.
  func reportLinuxGPU() throws {
    let device = try GLESDevice()
    print("GPU: \(device.renderer)")
    let target = try device.makeTarget(width: 2, height: 2)
    device.render(into: target, clear: .colour(SIMD4<Float>(1, 0, 0, 1))) { _ in }
    let pixels = try device.readPixels(target)
    guard pixels == Array(repeating: [UInt8](arrayLiteral: 0, 0, 255, 255), count: 4).flatMap({ $0 }) else {
      throw GPUReadbackFailure()
    }
    print("GLES offscreen clear/readback: passed (BGRA, 2 x 2)")
    print("This verifies offscreen rendering; window presentation and hardware performance are untested.")
  }

  private struct GPUReadbackFailure: Error, CustomStringConvertible {
    var description: String { "GLES returned unexpected pixels for a solid red target." }
  }
#endif
