#version 450
#extension GL_GOOGLE_include_directive : require
#include "cloudsSky.glsl"
// The sky: a sphere round the camera, shaded by the direction to each fragment.
layout(location = 0) in vec3 aPosition;
layout(location = 0) out vec3 vDir;

void main() {
  vDir = normalize(aPosition);
  gl_Position = projectionMatrix * modelViewMatrix * vec4(aPosition, 1.0);
}
