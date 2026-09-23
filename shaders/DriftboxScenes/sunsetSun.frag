#version 450
#extension GL_GOOGLE_include_directive : require
#include "sunsetSun.glsl"
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

void main() {
  vec2 p = vUv * 2.0 - 1.0;
  float r = length(p);
  if (r > 1.0) discard;
  vec3 colour = mix(uBottom, uTop, vUv.y);
  // The slats. They widen toward the bottom of the disc, which is the detail that makes
  // this read as the genre rather than as a sunset.
  float band = smoothstep(0.0, 1.0, vUv.y);
  float slat = step(0.34 + band * 0.6, fract(vUv.y * 17.0));
  float mask = mix(slat, 1.0, smoothstep(0.42, 0.95, vUv.y));
  float edge = smoothstep(1.0, 0.86, r);
  fragColor = vec4(colour * (1.0 + uBass * 0.7), mask * edge);
}
