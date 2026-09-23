#version 450
#extension GL_GOOGLE_include_directive : require
#include "convoyFlat.glsl"
layout(location = 0) out vec4 fragColor;

void main() {
  fragColor = vec4(uColour, uOpacity);
}
