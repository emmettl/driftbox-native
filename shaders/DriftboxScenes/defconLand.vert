#version 450
#extension GL_GOOGLE_include_directive : require
#include "defconLand.glsl"
// Defcon's territories: generated blobs, filled as fans, flat on the board.
layout(location = 0) in vec3 aPosition;

void main() {
  gl_Position = projectionMatrix * modelViewMatrix * vec4(aPosition, 1.0);
}
