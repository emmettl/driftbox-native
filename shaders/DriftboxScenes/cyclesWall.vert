#version 450
#extension GL_GOOGLE_include_directive : require
#include "cyclesWall.glsl"
// A light cycle's wall: a floor vertex and a top vertex at every corner of its trail, plus the
// bike itself as the leading edge.
layout(location = 0) in vec3 aPosition;
layout(location = 1) in float aAge;
layout(location = 0) out vec3 vColour;
layout(location = 1) out float vUp;
layout(location = 2) out float vFade;

void main() {
  // Every other vertex is the top of the wall, which is what the index list assumes.
  float aUp = float(gl_VertexIndex % 2);
  vec3 pos = aPosition;
  // The derez lifts the walls off the floor as they go, so the arena empties upward
  // instead of simply switching off.
  pos.y += uDerez * uDerez * 26.0 * aUp;
  vColour = uColour;
  vUp = aUp;
  // Older wall is dimmer, so the freshest corner is always the brightest thing on the
  // grid and the eye follows the bike rather than the mess behind it.
  vFade = clamp(1.0 - aAge * 0.11, 0.06, 1.0);
  gl_Position = projectionMatrix * modelViewMatrix * vec4(pos, 1.0);
}
