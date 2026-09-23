#version 450
#extension GL_GOOGLE_include_directive : require
#include "longhandGrid.glsl"
// Longhand's page: three's `GridHelper`, stood up into the page's plane, as a line list.
layout(location = 0) in vec3 aPosition;

void main() {
  gl_Position = projectionMatrix * modelViewMatrix * vec4(aPosition, 1.0);
}
