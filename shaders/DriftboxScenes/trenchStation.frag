#version 450
#extension GL_GOOGLE_include_directive : require
#include "trenchStation.glsl"
layout(location = 0) in float vFade;
layout(location = 1) in float vKind;
layout(location = 0) out vec4 fragColor;

void main() {
  if (vFade < 0.01) discard;
  // Structure is pale blue-white, like a vector monitor's phosphor; the greebles are
  // warmer, so the clutter separates from the walls it is bolted to.
  vec3 structure = vec3(0.62, 0.86, 1.0);
  vec3 greeble = vec3(1.0, 0.72, 0.45);
  vec3 colour = mix(structure, greeble, clamp(vKind, 0.0, 1.0));
  if (vKind > 1.5) colour = vec3(0.22, 0.85, 0.9);
  if (vKind > 2.5) colour = vec3(1.0, 0.36, 0.12) * (1.0 + uHigh * 1.4);
  fragColor = vec4(colour * (0.75 + uHigh * 0.9), vFade * (0.6 + uHigh * 0.4));
}
