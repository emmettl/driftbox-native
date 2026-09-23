#version 450
#extension GL_GOOGLE_include_directive : require
#include "dancersBeam.glsl"
// The Dancers' lights: four triangles from lamps above down to the floor, sweeping.
layout(location = 0) in vec3 aPosition;
layout(location = 1) in vec3 aColour;
layout(location = 2) in float aDrop;
layout(location = 0) out vec3 vColour;
layout(location = 1) out float vDrop;

void main() {
  vColour = aColour;
  vDrop = aDrop;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(aPosition, 1.0);
}
