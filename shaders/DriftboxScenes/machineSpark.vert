#version 450
#extension GL_GOOGLE_include_directive : require
#include "machineSpark.glsl"
#include "sprite.glsl"
// Machine's sparks, thrown from under the ram on every hit: a sprite each rather than a point,
// since a point with a size is not something every backend can draw.
layout(location = 0) in vec3 aPosition;
layout(location = 0) out float vFogDepth;

void main() {
  vec4 view = modelViewMatrix * vec4(aPosition, 1.0);
  // three's size attenuation: the world size against half the drawing buffer's height,
  // divided by the distance — so a spark is the same size in metres at any depth.
  float size = 0.075 * uScale / max(1e-4, -view.z);
  vFogDepth = -view.z;
  // A square sprite, as three's own point is: nothing reads where on it a fragment is.
  vec2 pointCoord;
  gl_Position = spriteCorner(projectionMatrix * view, size, pointCoord);
}
