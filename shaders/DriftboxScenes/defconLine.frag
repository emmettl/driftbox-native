#version 450
#extension GL_GOOGLE_include_directive : require
#include "defconLine.glsl"
layout(location = 0) out vec4 fragColor;

// Everything three's LineBasicMaterial does when it is given a colour and an opacity, which
// is the whole of what the graticule and the coast ask of it.
void main() {
  fragColor = vec4(uColour, uOpacity);
}
