#version 450
#extension GL_GOOGLE_include_directive : require
#include "saturnPlanet.glsl"
layout(location = 0) in vec3 vNormal;
layout(location = 1) in float vFlash;
layout(location = 2) in float vScar;
layout(location = 3) in vec2 vPointCoord;
layout(location = 0) out vec4 fragColor;

void main() {
  vec2 d = vPointCoord - 0.5;
  if (dot(d, d) > 0.25) discard;
  // Banded like a gas giant, by latitude: bands rather than a smooth gradient because
  // that is the one cue that says "gas giant" and not "moon".
  float band = 0.5 + 0.5 * sin(vNormal.y * 22.0);
  vec3 colour = mix(vec3(0.82, 0.68, 0.44), vec3(0.94, 0.86, 0.66), band);
  // A terminator, so it is lit from somewhere and reads as a sphere. Without this a
  // point cloud on a ball is a flat disc.
  float light = clamp(dot(vNormal, normalize(vec3(-0.55, 0.35, 0.75))), 0.0, 1.0);
  float shade = 0.06 + pow(light, 0.8) * 0.94;
  // Scars are dark and reddish — a bruise in the cloud tops, not a hole.
  colour = mix(colour, vec3(0.30, 0.10, 0.07), vScar * 0.85);
  colour += vec3(1.0, 0.95, 0.85) * vFlash * 2.6;
  float alpha = clamp(shade * 0.85 + vFlash + vScar * 0.3, 0.0, 1.0);
  fragColor = vec4(colour * (shade + uHigh * 0.12) + vec3(vFlash), alpha);
}
