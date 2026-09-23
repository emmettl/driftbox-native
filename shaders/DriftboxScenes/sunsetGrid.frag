#version 450
#extension GL_GOOGLE_include_directive : require
#include "sunsetGrid.glsl"
layout(location = 0) in vec2 vUv;
layout(location = 1) in float vPull;
layout(location = 0) out vec4 fragColor;

void main() {
  // Scroll toward the viewer. The lines come from the fract of the scaled uv, with the
  // width scaled by fwidth so distant lines stay one pixel wide instead of aliasing.
  vec2 uv = vec2(vUv.x * 60.0, vUv.y * 60.0 - uTime * 1.6);
  vec2 grid = abs(fract(uv - 0.5) - 0.5) / fwidth(uv);
  float lines = 1.0 - min(min(grid.x, grid.y), 1.0);
  float fade = 1.0 - smoothstep(0.0, 0.62, vUv.y);
  vec3 colour = mix(uNear, uFar, vUv.y);
  float glow = lines * fade * (0.55 + uHigh * 0.85);
  if (glow < 0.004) discard;
  // Lit where the finger is, so the warp is visible even on a still floor.
  vec3 lit = mix(colour * (0.7 + uHigh), vec3(1.0, 0.82, 0.42), clamp(vPull * 3.0, 0.0, 1.0));
  fragColor = vec4(lit, glow * (1.0 + vPull * 7.0));
}
