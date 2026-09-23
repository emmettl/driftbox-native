#version 450
#extension GL_GOOGLE_include_directive : require
#include "convoyRoad.glsl"
// Endless Convoy's road: a plane behind the column, whose grid runs under the convoy.
layout(location = 0) in vec3 aPosition;
layout(location = 1) in vec2 aUv;
layout(location = 0) out vec2 vUv;

void main() {
  vUv = aUv;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(aPosition, 1.0);
}
