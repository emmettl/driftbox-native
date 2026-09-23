#version 450
#extension GL_GOOGLE_include_directive : require
#include "stillwaterWater.glsl"
layout(location = 0) in float vLift;
layout(location = 1) in float vFade;
layout(location = 2) in vec2 vPointCoord;
layout(location = 0) out vec4 fragColor;

void main() {
  // Round points. Without this every "drop" is a square, which at 5px is obvious.
  vec2 d = vPointCoord - 0.5;
  if (dot(d, d) > 0.25) discard;
  if (vFade < 0.01) discard;
  // Still water is almost black. A ring passing lifts a point into cold blue-white, so
  // the only bright thing on screen is the thing that just happened.
  float energy = clamp(abs(vLift) * 1.5, 0.0, 1.0);
  vec3 colour = mix(vec3(0.10, 0.16, 0.30), vec3(0.70, 0.88, 1.0), energy);
  fragColor = vec4(colour * (0.55 + energy * 1.6 + uHigh * 0.25), vFade * (0.35 + energy * 0.65));
}
