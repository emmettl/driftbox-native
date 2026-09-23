#version 450
#extension GL_GOOGLE_include_directive : require
#include "cyclesGrid.glsl"
layout(location = 0) in vec2 vPos;
layout(location = 0) out vec4 fragColor;

// Cycles.arena.
const float ARENA = 44.0;

void main() {
  // Fading toward the edge of the arena, so the grid has no visible border. A hard edge
  // turns the game board into a rug on a floor.
  float away = length(vPos) / ARENA;
  float fade = 1.0 - smoothstep(0.45, 1.05, away);
  vec3 colour = mix(vec3(0.10, 0.42, 0.62), vec3(0.4, 0.92, 1.0), uBass);
  fragColor = vec4(colour * (1.0 + uBass + uDerez * 2.0), fade * (0.34 + uBass * 0.5 + uDerez * 0.7));
}
