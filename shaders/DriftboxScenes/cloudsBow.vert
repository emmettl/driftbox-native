#version 450
#extension GL_GOOGLE_include_directive : require
#include "cloudsBow.glsl"
// The rainbow: seven arcs as a line list, a colour per band.
layout(location = 0) in vec3 aPosition;
layout(location = 1) in vec3 aColour;
layout(location = 0) out vec3 vColour;

void main() {
  vColour = aColour;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(aPosition, 1.0);
}
