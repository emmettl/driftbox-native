#version 450
#extension GL_GOOGLE_include_directive : require
#include "defconTint.glsl"
// three's LineBasicMaterial with vertexColors on: the city glyphs, the trajectories and the
// blast rings.
layout(location = 0) in vec3 aPosition;
layout(location = 1) in vec3 aColour;
layout(location = 0) out vec3 vColour;

void main() {
  vColour = aColour;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(aPosition, 1.0);
}
