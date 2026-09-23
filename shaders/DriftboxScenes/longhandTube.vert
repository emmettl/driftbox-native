#version 450
#extension GL_GOOGLE_include_directive : require
#include "longhandInk.glsl"
// Longhand's tubing: a stroke's lattice, stored as the centre of the tube and the unit direction
// out to its skin, so the core and the halo are one lattice at two radii.
layout(location = 0) in vec3 aCentre;
layout(location = 1) in vec3 aDirection;

void main() {
  // The tube's skin, at whichever of the two radii is being drawn. The core is the mark
  // and the halo is the same mark four times as thick and almost transparent, which is
  // what makes the ink look lit from inside rather than merely bright.
  vec3 pos = aCentre + aDirection * uRadius;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(pos, 1.0);
}
