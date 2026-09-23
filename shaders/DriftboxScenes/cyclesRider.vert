#version 450
#extension GL_GOOGLE_include_directive : require
#include "cyclesGrid.glsl"
#include "sprite.glsl"
// The light cycles themselves: a dot at the head of every wall. A sprite rather than a point, so
// it is the same size on every backend; a rider is an instance.
layout(location = 0) in vec3 aPosition;
layout(location = 1) in vec3 aColour;
layout(location = 0) out vec3 vColour;
layout(location = 1) out vec2 vPointCoord;

void main() {
  vColour = aColour;
  // Sized in device pixels and not attenuated, so a rider is the same dot on a phone as
  // on a desktop.
  float size = 3.2 * uPixel;
  gl_Position = spriteCorner(projectionMatrix * modelViewMatrix * vec4(aPosition, 1.0), size, vPointCoord);
}
