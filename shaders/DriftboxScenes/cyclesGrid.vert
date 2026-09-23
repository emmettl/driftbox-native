#version 450
#extension GL_GOOGLE_include_directive : require
#include "cyclesGrid.glsl"
// The light cycles' game board: a line list across the arena floor.
layout(location = 0) in vec3 aPosition;
layout(location = 0) out vec2 vPos;

void main() {
  // The fade has to be worked out from the fragment's own position, not handed in per
  // vertex: every line across this grid has BOTH ends on the boundary, so an attribute
  // would interpolate from "fully faded" to "fully faded" and the whole grid would render
  // at zero alpha — invisible, with no error anywhere to say so.
  vPos = aPosition.xz;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(aPosition, 1.0);
}
