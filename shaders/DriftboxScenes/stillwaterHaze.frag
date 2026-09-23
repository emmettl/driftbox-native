#version 450
#extension GL_GOOGLE_include_directive : require
#include "stillwaterHaze.glsl"
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

void main() {
  // Brightest at the waterline and gone well before the top of the plane, so it is a band
  // of haze sitting on the horizon rather than a wash over the whole sky.
  float band = pow(1.0 - smoothstep(0.0, 0.55, vUv.y), 2.0);
  // A little wider across the middle, which stops it reading as a drawn rectangle.
  band *= 0.55 + 0.45 * sin(vUv.x * 3.14159);
  fragColor = vec4(vec3(0.08, 0.16, 0.34) * band * (1.0 + uBass * 0.9), band * 0.55);
}
