#version 450
#extension GL_GOOGLE_include_directive : require
#include "longhandDust.glsl"
#include "sprite.glsl"
// Longhand's dust: specks across the sheet, a sprite each rather than a point, since a point
// with a size is not something every backend can draw.
layout(location = 0) in vec3 aPosition;
layout(location = 0) out float vDepth;

void main() {
  vec4 view = modelViewMatrix * vec4(aPosition, 1.0);
  vDepth = -view.z;
  // Sized in pixels and not by distance, so the specks stay specks: dust on the glass
  // rather than a starfield with a near edge.
  float size = uSize;
  // A square sprite, as three's own point is: nothing reads where on it a fragment is.
  vec2 pointCoord;
  gl_Position = spriteCorner(projectionMatrix * view, size, pointCoord);
}
