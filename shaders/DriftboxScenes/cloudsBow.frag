#version 450
#extension GL_GOOGLE_include_directive : require
#include "cloudsBow.glsl"
layout(location = 0) in vec3 vColour;
layout(location = 0) out vec4 fragColor;

void main() {
  if (uShow < 0.01) discard;
  fragColor = vec4(vColour, uShow * 0.72);
}
