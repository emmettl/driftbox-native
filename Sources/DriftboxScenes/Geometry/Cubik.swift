#if canImport(Metal)
  import Metal
  import simd

  /// Cübik/Olympic: a white room made from the four inks on the single sleeve. The field is
  /// one instanced buffer and one draw call, and its cubes do not simply jump as one loudness
  /// meter — concentric rings are assigned to logarithmic frequency bands, while the low end
  /// launches a second wave through the whole floor. A kick moves the landscape, a synth note
  /// picks out one coloured ring, and a hat catches the top faces.
  public final class Cubik: GeometryScene {
    override public class var id: String { "cubik" }
    override public class var name: String { "Cubik" }
    override public class var accent: SIMD3<Float> { SIMD3(40, 70, 130) / 255 }
    override public class var background: SIMD3<Float> { SIMD3(0xef, 0xed, 0xe5) / 255 }

    static let side = 27
    static let count = side * side
    static let spacing: Float = 0.64
    static let bandCount = 12
    static let targetZ: Float = -1.8
    static let orbitRadius = (7.8 * 7.8 + (12.8 - targetZ) * (12.8 - targetZ)).squareRoot()
    static let orbitStart = atan2(Float(7.8), 12.8 - targetZ)
    /// One revolution in roughly a minute and a half: movement you feel before you notice.
    static let orbitSpeed = Float.pi * 2 / 92

    struct Uniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var normalMatrix = matrix_identity_float4x4
      var bands = (
        Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0),
        Float(0), Float(0), Float(0)
      )
      var time: Float = 0
      var bass: Float = 0
      var high: Float = 0
      var warp: Float = 0
      var touch = SIMD2<Float>(0.5, 0.5)
    }

    var uniforms = Uniforms()
    var smoothed = [Float](repeating: 0, count: Cubik.bandCount)
    var positions: MTLBuffer!
    var normals: MTLBuffer!
    var indices: MTLBuffer!
    var grid: MTLBuffer!
    var band: MTLBuffer!
    var ink: MTLBuffer!
    var indexCount = 0
    var pipelineState: MTLRenderPipelineState!
    var orbit = Cubik.orbitStart

    override public func build() throws {
      let cube = Box.build(width: 0.48, height: 1, depth: 0.48)
      positions = buffer(cube.positions)
      normals = buffer(cube.normals)
      indices = buffer(cube.indices)
      indexCount = cube.indices.count

      var grid: [SIMD2<Float>] = []
      var bands: [Float] = []
      var inks: [Float] = []
      let half = Float(Self.side - 1) / 2
      for z in 0..<Self.side {
        for x in 0..<Self.side {
          let gx = Float(x) - half
          let gz = Float(z) - half
          grid.append(SIMD2(gx, gz))
          bands.append(Float(Int((gx * gx + gz * gz).squareRoot() * 0.9) % Self.bandCount))
          // Broad diagonal blocks of colour: ordered like printing ink, not confetti.
          inks.append(Float(((x + 3) / 5 + (z + 2) / 4) % 4))
        }
      }
      self.grid = buffer(grid)
      band = buffer(bands)
      ink = buffer(inks)
      pipelineState = try pipeline(vertex: "cubikVertex", fragment: "cubikFragment", blend: .none)
    }

    override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
      let (bass, high) = input.wideLevels
      uniforms.time += dt * (0.64 + bass * 0.7)
      orbit = (orbit + dt * Self.orbitSpeed).truncatingRemainder(dividingBy: .pi * 2)
      uniforms.bass = glide(uniforms.bass, toward: bass, dt: dt, attack: 4, release: 2.6)
      uniforms.high = glide(uniforms.high, toward: high, dt: dt, attack: 6, release: 4)
      uniforms.warp = touchEnergy
      uniforms.touch = touchAt
      for lane in 0..<Self.bandCount {
        let raw = lane < input.bands.count ? input.bands[lane] : 0
        smoothed[lane] = glide(smoothed[lane], toward: raw, dt: dt, attack: 3.2, release: 2)
      }
      withUnsafeMutableBytes(of: &uniforms.bands) { raw in
        for lane in 0..<Self.bandCount {
          raw.storeBytes(of: smoothed[lane], toByteOffset: lane * MemoryLayout<Float>.stride, as: Float.self)
        }
      }

      // A slow lap around the board keeps the field changing even between interactions.
      // Horizontal touch nudges the angle rather than sliding the camera off its orbit, so the
      // gesture and the autonomous move compose instead of fighting one another.
      let angle = orbit + (touchAt.x - 0.5) * touchEnergy * 0.42
      let radius = Self.orbitRadius - uniforms.bass * 1.1
      let want = SIMD3(
        sin(angle) * radius, 9.3 + (touchAt.y - 0.5) * touchEnergy * 2.4,
        Self.targetZ + cos(angle) * radius)
      camera.position += (want - camera.position) * min(1, dt * 2.2)
      camera.target = SIMD3(0, 0.6, Self.targetZ)
      camera.fovDegrees = 46
      camera.far = 80
      uniforms.projectionMatrix = camera.projection(aspect: aspect)
      uniforms.modelViewMatrix = camera.view
      uniforms.normalMatrix = camera.view
    }

    override public func encode(_ encoder: MTLRenderCommandEncoder) {
      encoder.setDepthStencilState(depthState)
      encoder.setRenderPipelineState(pipelineState)
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
      encoder.setVertexBuffer(positions, offset: 0, index: 1)
      encoder.setVertexBuffer(normals, offset: 0, index: 2)
      encoder.setVertexBuffer(grid, offset: 0, index: 3)
      encoder.setVertexBuffer(band, offset: 0, index: 4)
      encoder.setVertexBuffer(ink, offset: 0, index: 5)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
      encoder.drawIndexedPrimitives(
        type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: indices,
        indexBufferOffset: 0, instanceCount: Self.count)
    }

    static let source = """

      struct CubikUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float4x4 normalMatrix;
        float uBands[\(bandCount)];
        float uTime;
        float uBass;
        float uHigh;
        float uWarp;
        float2 uTouch;
      };
      struct CubikVarying {
        float4 position [[position]];
        float3 vNormal;
        float vInk;
        float vEnergy;
        float vDepth;
      };

      vertex CubikVarying cubikVertex(
        uint vid [[vertex_id]], uint iid [[instance_id]], constant CubikUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]], constant float3 *vertexNormals [[buffer(2)]],
        constant float2 *aGridIn [[buffer(3)]], constant float *aBandIn [[buffer(4)]],
        constant float *aInkIn [[buffer(5)]]
      ) {
        float uTime = u.uTime, uBass = u.uBass, uWarp = u.uWarp;
        float2 aGrid = aGridIn[iid];
        float aBand = aBandIn[iid];
        float3 position = vertices[vid];

        float2 centre = (u.uTouch - 0.5) * float2(\(Float(side) * 0.72), \(Float(side) * -0.72)) * uWarp;
        float radius = length(aGrid - centre);
        float lane = u.uBands[int(aBand + 0.5)];

        // Two waves: the spectrum makes persistent rings, the kick sends a sharp front
        // outwards. The latter moves faster when the record gets louder.
        float standing = 0.5 + 0.5 * sin(radius * 0.92 - uTime * 2.1 + aBand * 0.33);
        float travelling = max(0.0, sin(radius * 1.32 - uTime * (3.2 + uBass * 1.2)));
        // A broad crest reads as a wave passing through the field. A fifth-power spike made
        // each row switch on and off like a bank of camera flashes.
        travelling = pow(travelling, 3.0);
        float energy = lane * (0.34 + standing * 0.55) + uBass * travelling * 0.62;
        // Full-scale analysers are common once the limiter is working, so the visual range is
        // compressed here: a loud chorus is still a landscape rather than a solid wall.
        energy = min(1.12, energy);

        // A little height while silent keeps this a field of objects rather than a checkerboard.
        float height = 0.22 + energy * 2.15;
        float3 pos = position;
        pos.y *= height;
        pos.y += height * 0.5;
        // The distorted synth bends the towers rather than merely making them taller. Since the
        // displacement grows up the cube, the feet remain locked to the grid.
        float bend = sin(aGrid.x * 0.71 + aGrid.y * 0.43 + uTime * 2.7);
        pos.x += position.y * bend * energy * 0.22;
        pos.z += position.y * cos(bend * 2.2 + uTime) * energy * 0.13;
        pos.x += aGrid.x * \(spacing);
        pos.z += aGrid.y * \(spacing);

        CubikVarying out;
        float4 view = u.modelViewMatrix * float4(pos, 1.0);
        out.position = u.projectionMatrix * view;
        out.vNormal = normalize((u.normalMatrix * float4(vertexNormals[vid], 0.0)).xyz);
        out.vInk = aInkIn[iid];
        out.vEnergy = energy;
        out.vDepth = clamp((-view.z - 7.0) / 24.0, 0.0, 1.0);
        return out;
      }

      fragment float4 cubikFragment(CubikVarying in [[stage_in]], constant CubikUniforms &u [[buffer(0)]]) {
        float3 red = float3(0.91, 0.13, 0.16);
        float3 blue = float3(0.08, 0.35, 0.78);
        float3 yellow = float3(1.0, 0.66, 0.04);
        float3 green = float3(0.03, 0.58, 0.28);
        float3 ink = red;
        if (in.vInk > 0.5) ink = blue;
        if (in.vInk > 1.5) ink = yellow;
        if (in.vInk > 2.5) ink = green;
        float3 light = normalize(float3(-0.45, 0.82, 0.35));
        float face = 0.54 + max(0.0, dot(in.vNormal, light)) * 0.58;
        float top = pow(max(0.0, in.vNormal.y), 5.0);
        float3 colour = ink * face;
        colour = mix(colour, float3(1.0), top * u.uHigh * 0.72);
        colour += ink * min(0.28, in.vEnergy * 0.08);
        // The far rows dissolve into the paper-white room instead of ending at a hard edge.
        colour = mix(colour, float3(0.94, 0.93, 0.89), smoothstep(0.68, 1.0, in.vDepth) * 0.72);
        return float4(colour, 1.0);
      }

      """
  }
#endif
