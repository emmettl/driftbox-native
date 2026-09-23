#version 450
#extension GL_GOOGLE_include_directive : require
#include "longhandInk.glsl"
layout(location = 0) out vec4 fragColor;

void main() {
  // three shows one side of a surface, and here that is not cosmetic: the halo is additive,
  // so drawing the far wall of the tube as well would double its glow. The Metal scene culled
  // back faces; the layer has no cull mode, so they are thrown away here instead.
  if (!gl_FrontFacing) discard;
  // Unlit and flat, as three's basic material is. The ink is a light source in the
  // scene, not something the scene lights.
  fragColor = vec4(uColour, uOpacity);
}
