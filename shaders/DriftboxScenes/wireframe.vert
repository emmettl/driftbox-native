#version 450
#extension GL_GOOGLE_include_directive : require
#include "wireframe.glsl"
// Flying down a wireframe corridor: sixty-four hexagonal ribs and the rails joining them, in one
// line list moved entirely here, surging on every kick.
layout(location = 0) in vec3 aPosition;
layout(location = 1) in float aDepth;
layout(location = 0) out float vFade;
layout(location = 1) out float vPulse;

const float DEPTH = 120.0;

void main() {
  vec3 pos = aPosition;
  // Travel. Everything slides toward the camera and wraps at the near end.
  float z = mod(aDepth + uTime, DEPTH);
  pos.z = z - DEPTH;
  // The corridor breathes on the low end, each rib slightly out of step with its neighbours.
  float phase = z * 0.09;
  float breathe = 1.0 + uBass * 0.42 * (0.6 + 0.4 * sin(phase));
  pos.xy *= breathe;
  // A waist that travels past you: exactly two waves per DEPTH, so it matches across the wrap.
  pos.xy *= 1.0 + sin(z * 0.104720) * 0.17;
  // Steered by the finger, more strongly the further away it is.
  float far = z / DEPTH;
  pos.x += (uTouch.x - 0.5) * uWarp * 78.0 * far * far;
  pos.y += (uTouch.y - 0.5) * uWarp * 56.0 * far * far;
  pos.xy *= 1.0 + sin(z * 0.16 - uTime * 3.0) * uWarp * 0.28;
  vFade = 1.0 - smoothstep(0.42, 1.0, far);
  vPulse = 1.0 - fract(phase * 0.5 - uTime * 0.1);
  gl_Position = projectionMatrix * modelViewMatrix * vec4(pos, 1.0);
}
