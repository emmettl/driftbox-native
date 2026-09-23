#version 450
#extension GL_GOOGLE_include_directive : require
#include "canvas.glsl"
// Every mark on a canvas is one instanced quad: the unit square, placed on the page by the mark's
// own transform — the canvas's transform when it was made, and the mark's size — so a rectangle,
// an ellipse, a glyph or a copy of the page all draw through the same six vertices.
layout(location = 0) in vec4 aAxes;    // where the unit square's x and y axes go: (x.x, x.y, y.x, y.y)
layout(location = 1) in vec4 aOrigin;  // where its corner goes, and the kind of mark
layout(location = 2) in vec4 aColour;  // straight alpha
layout(location = 3) in vec4 aTexture; // for a glyph or an image: where in the texture, u0 v0 u1 v1
layout(location = 4) in vec4 aClip;    // the page's clip when it was made: x0 y0 x1 y1, in pixels

layout(location = 0) out vec2 vLocal;
layout(location = 1) out vec2 vPage;
layout(location = 2) flat out float vKind;
layout(location = 3) out vec4 vColour;
layout(location = 4) out vec2 vUv;
layout(location = 5) flat out vec4 vClip;

const vec2 corners[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 0), vec2(1, 1), vec2(0, 1));

void main() {
  vec2 corner = corners[gl_VertexIndex];
  vec2 xAxis = aAxes.xy;
  vec2 yAxis = aAxes.zw;
  float kind = aOrigin.z;
  // A shape's edge is antialiased, so its quad reaches a pixel past it on every side, or the
  // pixels its edge half covers would have no fragment to be half covered in. A glyph's bitmap
  // and an image are antialiased already, and drawn exactly where they are.
  vec2 pad = kind < KIND_GLYPH ? vec2(1.0 / max(length(xAxis), 1e-6), 1.0 / max(length(yAxis), 1e-6)) : vec2(0.0);
  vec2 local = mix(-pad, 1.0 + pad, corner);
  vec2 page = aOrigin.xy + xAxis * local.x + yAxis * local.y;
  vLocal = local;
  vPage = page;
  vKind = kind;
  vColour = aColour;
  vUv = mix(aTexture.xy, aTexture.zw, corner);
  vClip = aClip;
  gl_Position = vec4(page.x / uPage.x * 2.0 - 1.0, 1.0 - page.y / uPage.y * 2.0, 0.0, 1.0);
}
