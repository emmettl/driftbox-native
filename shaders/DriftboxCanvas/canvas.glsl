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
// A rectangle with rounded corners, filled top to bottom from its colour to a second one; and one
// drawn as a border inside its edge. For an interface, which is not turned: measured in the page's
// pixels, the corners' radius in the mark's origin's w.
const float KIND_ROUNDED = 4.0;
const float KIND_BORDER = 5.0;
