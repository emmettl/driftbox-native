// What both of the canvas's stages read. The page is `uPage` pixels, with the canvas's own
// coordinates: x to the right, y down, the origin at the top left.
layout(set = 0, binding = 0, std140) uniform CanvasUniforms {
  vec2 uPage;
  // 1 while drawing under the multiply blend, which multiplies what is there by what is drawn:
  // a mark then gives white where it does not cover, so that it leaves the page alone there.
  float uMultiply;
};

// What a mark is, which decides what covers it.
const float KIND_RECT = 0.0;
const float KIND_ELLIPSE = 1.0;
const float KIND_GLYPH = 2.0;
const float KIND_IMAGE = 3.0;
