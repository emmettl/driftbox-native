#version 450
#extension GL_GOOGLE_include_directive : require
#include "dancersFigure.glsl"
layout(location = 0) in vec3 vColour;
layout(location = 1) in float vGlow;
layout(location = 0) out vec4 fragColor;

void main() {
  fragColor = vec4(vColour * (0.8 + vGlow * 1.6 + uBass * 0.5), 0.55 + vGlow * 0.45);
}
