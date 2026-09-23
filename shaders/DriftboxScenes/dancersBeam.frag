#version 450
#extension GL_GOOGLE_include_directive : require
#include "dancersBeam.glsl"
layout(location = 0) in vec3 vColour;
layout(location = 1) in float vDrop;
layout(location = 0) out vec4 fragColor;

void main() {
  // Brightest at the lamp and gone by the floor, which is what a beam in a smoky room
  // does — and without the falloff a triangle of flat colour reads as a wedge of card.
  float fade = pow(1.0 - vDrop, 2.2);
  fragColor = vec4(vColour * fade * (0.5 + uHigh * 1.2), fade * 0.24);
}
