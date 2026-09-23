#version 450
#extension GL_GOOGLE_include_directive : require
#include "machineSpark.glsl"
#include "machine.glsl"
layout(location = 0) in float vFogDepth;
layout(location = 0) out vec4 fragColor;

void main() {
  // A points material is tone mapped, encoded and fogged like any other, so the sparks are
  // not the raw colour they are written as either.
  vec3 colour = machineFog(machineEncode(machineTonemap(uColour)), vFogDepth);
  fragColor = vec4(colour, uOpacity);
}
