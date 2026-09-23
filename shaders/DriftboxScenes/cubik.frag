#version 450
#extension GL_GOOGLE_include_directive : require
#include "cubik.glsl"
layout(location = 0) in vec3 vNormal;
layout(location = 1) in float vInk;
layout(location = 2) in float vEnergy;
layout(location = 3) in float vDepth;
layout(location = 0) out vec4 fragColor;

void main() {
  vec3 red = vec3(0.91, 0.13, 0.16);
  vec3 blue = vec3(0.08, 0.35, 0.78);
  vec3 yellow = vec3(1.0, 0.66, 0.04);
  vec3 green = vec3(0.03, 0.58, 0.28);
  vec3 ink = red;
  if (vInk > 0.5) ink = blue;
  if (vInk > 1.5) ink = yellow;
  if (vInk > 2.5) ink = green;
  vec3 light = normalize(vec3(-0.45, 0.82, 0.35));
  float face = 0.54 + max(0.0, dot(vNormal, light)) * 0.58;
  float top = pow(max(0.0, vNormal.y), 5.0);
  vec3 colour = ink * face;
  colour = mix(colour, vec3(1.0), top * uHigh * 0.72);
  colour += ink * min(0.28, vEnergy * 0.08);
  // The far rows dissolve into the paper-white room instead of ending at a hard edge.
  colour = mix(colour, vec3(0.94, 0.93, 0.89), smoothstep(0.68, 1.0, vDepth) * 0.72);
  fragColor = vec4(colour, 1.0);
}
