#version 450
#extension GL_GOOGLE_include_directive : require
#include "defconLand.glsl"
layout(location = 0) out vec4 fragColor;

void main() {
  // The glow the original has under its landmasses. Brightest inland and falling away at the
  // coast, so the fill and the outline are the same object rather than a shape with a line
  // drawn round it.
  vec3 blue = vec3(0.05, 0.21, 0.72);
  vec3 hot = vec3(0.35, 0.12, 0.30);
  vec3 colour = mix(blue, hot, uAlert * 0.6);
  fragColor = vec4(colour * (0.62 + uBass * 0.5), 0.55);
}
