#version 450
#extension GL_GOOGLE_include_directive : require
#include "defconLine.glsl"
// three's LineBasicMaterial without vertex colours: the graticule and the coast.
layout(location = 0) in vec3 aPosition;

void main() {
  gl_Position = projectionMatrix * modelViewMatrix * vec4(aPosition, 1.0);
}
