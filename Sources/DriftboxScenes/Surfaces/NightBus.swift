#if canImport(Metal)
  import simd

  /// The camera is the passenger: upstairs, after midnight, watching sodium lamps and lit
  /// windows slide past wet glass. The city moves steadily, bass makes each lamp bloom, and hats
  /// pull rain down the pane faster than either. Touch does not steer the bus: it wipes a clear
  /// patch in the condensation.
  ///
  /// A surface with its own clocks: time runs faster with the highs and travel with the bass,
  /// and the bands are the web's `readLevels` rather than its eight bands.
  public final class NightBus: SurfaceScene {
    override public class var id: String { "nightbus" }
    override public class var name: String { "Night Bus" }
    override public class var accent: SIMD3<Float> { SIMD3(255, 232, 190) / 255 }
    override public class var fragmentFunction: String { "nightBus" }

    override func advance(_ input: SceneInput, size: SIMD2<Int>) {
      let dt = Float(min(input.time - (lastTime ?? input.time), 0.1))
      let travel = uniforms.travel
      let time = uniforms.time
      super.advance(input, size: size)
      let levels = input.wideLevels
      uniforms.time = time + dt * (0.72 + levels.high * 2.8)
      uniforms.travel = input.running ? travel + dt * (0.035 + levels.bass * 0.08) : travel
      uniforms.bass = Analyser.ease(bass, toward: levels.bass, dt: dt, fall: 3.4)
      uniforms.high = Analyser.ease(high, toward: levels.high, dt: dt, fall: 4.8)
      bass = uniforms.bass
      high = uniforms.high
    }

    private var bass: Float = 0
    private var high: Float = 0

    static let source = """

      static float nightBusHash11(float p) {
        p = fract(p * 0.1031);
        p *= p + 33.33;
        p *= p + p;
        return fract(p);
      }
      static float nightBusHash21(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
      }
      static float nightBusBuilding(float2 uv, float speed, float cells, float near, thread float &windowLight, float uTravel) {
        float world = uv.x + uTravel * speed;
        float id = floor(world * cells);
        float local = fract(world * cells);
        float height = near + nightBusHash11(id * 1.71) * (0.28 + near * 0.18);
        float body = step(uv.y, height) * step(0.135, uv.y);
        body *= smoothstep(0.025, 0.06, local) * smoothstep(0.025, 0.06, 1.0 - local);
        float2 windowGrid = float2(local * 4.0, uv.y * (17.0 + cells * 0.15));
        float2 windowCell = floor(windowGrid);
        float2 inWindow = fract(windowGrid);
        float pane = smoothstep(0.24, 0.31, inWindow.x)
          * smoothstep(0.24, 0.31, inWindow.y)
          * smoothstep(0.24, 0.31, 1.0 - inWindow.x)
          * smoothstep(0.24, 0.31, 1.0 - inWindow.y);
        float occupied = step(0.68, nightBusHash21(windowCell + float2(id, id * 0.31)));
        windowLight = pane * occupied * body;
        return body;
      }
      static float nightBusRain(float2 uv, float scale, float seed, float uTime) {
        // Lean every drop slightly with the bus's motion. Separate scales make a near and far
        // layer, so this reads as glass with depth rather than a repeated screen texture.
        float2 grid = uv * float2(18.0, 9.0) * scale;
        grid.x += grid.y * 0.22;
        float2 cell = floor(grid);
        float2 local = fract(grid);
        float random = nightBusHash21(cell + seed);
        float x = 0.18 + random * 0.64;
        float fall = fract(local.y + uTime * (0.28 + random * 0.34) + random);
        float streakLine = exp(-abs(local.x - x) * (76.0 + scale * 18.0));
        float tail = smoothstep(0.88, 0.24, fall) * smoothstep(0.01, 0.08, fall);
        float bead = 1.0 - smoothstep(0.025, 0.11, length(float2(local.x - x, fall - 0.08)));
        return streakLine * tail * (0.3 + random * 0.55) + bead * 0.72;
      }

      fragment float4 nightBus(Full in [[stage_in]], constant SurfaceUniforms &u [[buffer(0)]]) {
        \(SurfaceScene.aliases)
        float uAspect = uSize.x / max(1.0, uSize.y);
        float2 uv = vUv;
        float2 centred = (uv - 0.5) * float2(uAspect, 1.0);

        float3 skyTop = float3(0.012, 0.02, 0.055);
        float3 skyLow = float3(0.055, 0.075, 0.12);
        float3 colour = mix(skyLow, skyTop, smoothstep(0.18, 0.95, uv.y));

        // Three parallax streets. Their silhouettes overlap, but their windows do not travel
        // at the same speed; that disagreement is what makes a flat shader feel deep.
        float farWindows = 0.0;
        float farBody = nightBusBuilding(uv, 0.23, 7.0, 0.25, farWindows, uTravel);
        colour = mix(colour, float3(0.035, 0.055, 0.09), farBody);
        colour += farWindows * float3(0.18, 0.42, 0.55) * (0.32 + uHigh * 0.42);

        float midWindows = 0.0;
        float midBody = nightBusBuilding(uv, 0.46, 10.0, 0.2, midWindows, uTravel);
        colour = mix(colour, float3(0.024, 0.032, 0.052), midBody * 0.9);
        colour += midWindows * float3(0.95, 0.56, 0.25) * (0.48 + uBass * 0.52);

        float nearWindows = 0.0;
        float nearBody = nightBusBuilding(uv, 0.78, 14.0, 0.14, nearWindows, uTravel);
        colour = mix(colour, float3(0.014, 0.018, 0.029), nearBody * 0.95);
        colour += nearWindows * float3(0.2, 0.78, 0.82) * (0.38 + uHigh * 0.5);

        // Street lamps pass slowly enough to become events. Bass does not move them — it
        // blooms the sodium light against the wet window when they cross.
        float lampWorld = uv.x + uTravel * 0.9;
        float lampCell = floor(lampWorld * 3.2);
        float lampX = fract(lampWorld * 3.2);
        float lampSeed = nightBusHash11(lampCell * 4.13);
        float lampCentre = 0.22 + lampSeed * 0.56;
        float lampDistance = length(float2((lampX - lampCentre) * 1.7, (uv.y - 0.58) * 0.82));
        float lamp = exp(-lampDistance * (18.0 - uBass * 7.0));
        float post = exp(-abs(lampX - lampCentre) * 180.0) * step(uv.y, 0.58) * step(0.17, uv.y);
        colour += float3(1.0, 0.43, 0.1) * (lamp * (0.42 + uBass * 1.3) + post * 0.13);

        // Road and its reflected lights. Long streaks are more useful than lane markings:
        // through rain, the reflection is what tells you the surface is there.
        float road = 1.0 - smoothstep(0.13, 0.205, uv.y);
        colour = mix(colour, float3(0.012, 0.017, 0.024), road * 0.88);
        float streakX = fract((uv.x + uTravel * 1.45) * 8.0);
        float streak = exp(-abs(streakX - 0.5) * 20.0) * road * smoothstep(0.015, 0.17, uv.y);
        colour += streak * mix(float3(0.08, 0.42, 0.62), float3(0.95, 0.25, 0.16), nightBusHash11(floor((uv.x + uTravel * 1.45) * 8.0))) * (0.28 + uBass * 0.42);

        // Condensation softens contrast without sampling a second image. Touch clears an
        // aspect-correct patch rather than a stretched oval on a phone.
        float2 touchPoint = (uTouch.xy - 0.5) * float2(uAspect, 1.0);
        float clearPatch = (1.0 - smoothstep(0.075, 0.24, length(centred - touchPoint))) * uTouch.z;
        float mistNoise = nightBusHash21(floor(uv * float2(38.0, 52.0)));
        float mist = (0.2 + mistNoise * 0.055) * (1.0 - clearPatch * 0.92);
        colour = mix(colour, float3(0.17, 0.21, 0.27), mist);

        float drops = nightBusRain(uv, 1.0, 7.0, uTime) + nightBusRain(uv + float2(0.17, 0.03), 1.65, 31.0, uTime) * 0.6;
        drops *= 0.46 + uHigh * 1.5;
        colour += drops * float3(0.46, 0.68, 0.82) * (1.0 - clearPatch * 0.42);

        // The bus window frame makes the point of view explicit. Without it this is a city
        // wallpaper; with it the viewer is sitting somewhere and travelling.
        float edge = step(uv.x, 0.038) + step(0.962, uv.x) + step(uv.y, 0.045) + step(0.955, uv.y);
        float rail = (1.0 - smoothstep(0.0, 0.012, abs(uv.y - 0.21))) * 0.84;
        float rubber = (1.0 - smoothstep(0.0, 0.007, abs(uv.y - 0.225))) * 0.52;
        colour = mix(colour, float3(0.025, 0.027, 0.032), clamp(edge + rail, 0.0, 1.0));
        colour = mix(colour, float3(0.11, 0.12, 0.13), rubber);

        float vignette = smoothstep(0.92, 0.24, length(centred * float2(0.72, 1.0)));
        colour *= 0.62 + vignette * 0.38;
        colour += uBass * 0.025;

        return float4(colour, 1.0);
      }

      """
  }
#endif
