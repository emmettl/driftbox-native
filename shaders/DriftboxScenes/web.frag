#version 450
#extension GL_GOOGLE_include_directive : require
#include "web.glsl"
layout(location = 0) in float vLane;
layout(location = 1) in float vRing;
layout(location = 2) in float vHeat;
layout(location = 3) in float vHole;
layout(location = 0) out vec4 fragColor;

// Hue to RGB, so the whole web can cycle through the spectrum rather than crossfading
// between two chosen colours. Tempest does not have a palette; it has all of them.
vec3 webHue(float h) {
  vec3 k = mod(vec3(5.0, 3.0, 1.0) + h * 6.0, 6.0);
  return clamp(min(k, 4.0 - k), 0.0, 1.0);
}

void main() {
  // Hue runs around the web AND drifts with time, so neighbouring lanes are never the
  // same colour and the whole thing cycles.
  float h = fract(vLane / 16.0 + uTime * 0.06 + vRing * 0.15);
  vec3 colour = webHue(h);
  // Brightest at the rim, and much brighter on a loud lane.
  float bright = (0.16 + vRing * 0.5) + vHeat * 2.6 + uHigh * 0.3;
  // The accretion ring: whatever is falling hardest goes white, so the hole has an edge.
  colour = mix(colour, vec3(1.0), vHole * 0.55);
  bright += vHole * vHole * 2.2;
  fragColor = vec4(colour * bright, clamp(0.25 + vHeat * 1.8 + vRing * 0.3 + vHole, 0.0, 1.0));
}
