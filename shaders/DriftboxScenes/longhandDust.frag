#version 450
#extension GL_GOOGLE_include_directive : require
#include "longhandDust.glsl"
layout(location = 0) in float vDepth;
layout(location = 0) out vec4 fragColor;

void main() {
  // The scene's fog, which reaches nothing else. A square sprite a couple of pixels
  // across, as three's own point is — there is no room in it for a round mask.
  float fog = smoothstep(uFogNear, uFogFar, vDepth);
  fragColor = vec4(mix(uColour, uFogColour, fog), uOpacity);
}
