#version 450
#extension GL_GOOGLE_include_directive : require
#include "cloudsSky.glsl"
layout(location = 0) in vec3 vDir;
layout(location = 0) out vec4 fragColor;

void main() {
  vec3 dir = normalize(vDir);
  // Deep at the zenith, pale at the horizon. Every real sky does this and it is most of
  // what stops a flat blue fill reading as a wall.
  float up = clamp(dir.y * 0.5 + 0.5, 0.0, 1.0);
  vec3 high = vec3(0.16, 0.44, 0.86);
  vec3 low = vec3(0.72, 0.88, 0.98);
  vec3 sky = mix(low, high, pow(up, 0.7));

  // And a broad warm glow around the sun, which is what makes it feel like an afternoon
  // rather than a colour swatch.
  // The halo exponent matters more than it looks. At 3 the glow spreads over sixty
  // degrees, which on a portrait phone is most of the frame — so with the sun anywhere
  // near the edge you see only its flank and it reads as a white band down one side
  // rather than as a sun at all.
  float toward = max(0.0, dot(dir, normalize(uSun)));
  sky += vec3(1.0, 0.94, 0.76) * (pow(toward, 26.0) * 1.1 + pow(toward, 7.0) * 0.2);

  fragColor = vec4(sky * (1.0 + uBass * 0.1), 1.0);
}
