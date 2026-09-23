#version 450
#extension GL_GOOGLE_include_directive : require
#include "longhandInk.glsl"
// Longhand's nibs, the tip and the playhead: one unit ball, placed and sized per draw.
layout(location = 0) in vec3 aPosition;

void main() {
  vec3 pos = uOrigin + aPosition * uRadius;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(pos, 1.0);
}
