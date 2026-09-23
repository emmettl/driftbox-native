#version 450
#extension GL_GOOGLE_include_directive : require
#include "wireframe.glsl"
layout(location = 0) in float vFade;
layout(location = 1) in float vPulse;
layout(location = 0) out vec4 fragColor;

void main() {
  if (vFade < 0.01) discard;
  // Two colours down the length, so the corridor has depth cueing beyond brightness.
  vec3 colour = mix(uFar, uNear, vFade);
  // Highs run a bright band down the tunnel. Hats become something travelling.
  colour += vec3(0.5, 0.9, 1.0) * pow(vPulse, 6.0) * uHigh * 1.4;
  fragColor = vec4(colour, vFade * (0.85 + uHigh * 0.5));
}
