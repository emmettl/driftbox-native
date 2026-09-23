#version 450
#extension GL_GOOGLE_include_directive : require
#include "cyclesWall.glsl"
layout(location = 0) in vec3 vColour;
layout(location = 1) in float vUp;
layout(location = 2) in float vFade;
layout(location = 0) out vec4 fragColor;

void main() {
  // Brightest along the top edge and at the floor line, dimmer through the middle. A
  // flat-shaded slab reads as coloured glass; a light wall is an edge with a glow hanging
  // off it, and those two bands are the whole difference.
  float edge = pow(vUp, 3.0) + pow(1.0 - vUp, 6.0) * 0.7;
  vec3 colour = mix(vColour, vec3(1.0), edge * 0.55 + uDerez);
  float alpha = (0.13 + edge * 0.75) * vFade * (1.0 - uDerez * 0.75);
  fragColor = vec4(colour * (0.8 + edge * 1.7 + uBass * 0.5 + uDerez * 3.0), alpha);
}
