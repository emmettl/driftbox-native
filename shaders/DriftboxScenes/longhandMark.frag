#version 450
#extension GL_GOOGLE_include_directive : require
#include "longhandInk.glsl"
layout(location = 0) out vec4 fragColor;

void main() {
  // Unlit and flat, as three's basic material is. The ink is a light source in the
  // scene, not something the scene lights.
  fragColor = vec4(uColour, uOpacity);
}
