#version 450
#extension GL_GOOGLE_include_directive : require
#include "canvas.glsl"
// Coverage for each kind of mark, antialiased as a browser's canvas and CoreGraphics both draw:
// a pixel an edge half crosses is half covered.
layout(set = 0, binding = 1) uniform sampler2D atlas;
layout(set = 0, binding = 2) uniform sampler2D image;

layout(location = 0) in vec2 vLocal;
layout(location = 1) in vec2 vPage;
layout(location = 2) flat in float vKind;
layout(location = 3) in vec4 vColour;
layout(location = 4) in vec2 vUv;
layout(location = 5) flat in vec4 vClip;
layout(location = 6) flat in vec4 vExtra;
layout(location = 7) flat in vec3 vShape;
layout(location = 0) out vec4 fragColor;

// How much of this pixel lies inside the unit square, from how far its centre is from the nearest
// edge, in pixels, across and down.
float rectangle(vec2 local) {
  vec2 inside = min(local, 1.0 - local) / max(fwidth(local), vec2(1e-6));
  vec2 covered = clamp(inside + 0.5, 0.0, 1.0);
  return covered.x * covered.y;
}

// The same for the ellipse the unit square holds.
float ellipse(vec2 local) {
  float reach = length(local * 2.0 - 1.0);
  return clamp(0.5 - (reach - 1.0) / max(fwidth(reach), 1e-6), 0.0, 1.0);
}

// How far this pixel's centre is outside a rectangle with rounded corners, in pixels: negative
// inside. The rectangle is `size` pixels, its corners `radius`.
float roundedDistance(vec2 local, vec2 size, float radius) {
  float r = min(radius, 0.5 * min(size.x, size.y));
  vec2 q = abs((local - 0.5) * size) - 0.5 * size + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// How far this pixel's centre is outside an arc `width` pixels wide round the circle the mark's
// square holds, running clockwise from the top between `from` and `to`, with round ends.
float arcDistance(vec2 local, vec2 size, float width, float from, float to) {
  vec2 p = (local - 0.5) * size;
  float r = 0.5 * min(size.x, size.y) - 0.5 * width;
  float angle = atan(p.x, -p.y);
  if (angle >= from && angle <= to) return abs(length(p) - r) - 0.5 * width;
  vec2 start = r * vec2(sin(from), -cos(from));
  vec2 end = r * vec2(sin(to), -cos(to));
  return min(length(p - start), length(p - end)) - 0.5 * width;
}

void main() {
  // The clip, antialiased at its edge as the marks are.
  vec2 fromEdge = min(vPage - vClip.xy, vClip.zw - vPage);
  float clipped = clamp(min(fromEdge.x, fromEdge.y) + 0.5, 0.0, 1.0);

  vec4 colour = vColour;
  float coverage;
  if (vKind == KIND_RECT) {
    coverage = rectangle(vLocal);
  } else if (vKind == KIND_ELLIPSE) {
    coverage = ellipse(vLocal);
  } else if (vKind == KIND_ROUNDED) {
    coverage = clamp(0.5 - roundedDistance(vLocal, vShape.xy, vShape.z), 0.0, 1.0);
    colour = mix(vColour, vExtra, clamp(vLocal.y, 0.0, 1.0));
  } else if (vKind == KIND_BORDER) {
    float d = roundedDistance(vLocal, vShape.xy, vShape.z);
    coverage = clamp(0.5 - d, 0.0, 1.0) - clamp(0.5 - (d + vExtra.x), 0.0, 1.0);
  } else if (vKind == KIND_ARC) {
    coverage = clamp(0.5 - arcDistance(vLocal, vShape.xy, vExtra.x, vExtra.y, vExtra.z), 0.0, 1.0);
  } else if (vKind == KIND_GLYPH) {
    coverage = texture(atlas, vUv).a;
  } else {
    colour = texture(image, vUv);
    coverage = 1.0;
  }
  float alpha = colour.a * coverage * clipped;
  if (alpha <= 0.0) discard;
  fragColor = uMultiply > 0.5 ? vec4(mix(vec3(1.0), colour.rgb, alpha), 1.0) : vec4(colour.rgb, alpha);
}
