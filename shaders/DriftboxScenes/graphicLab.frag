#version 450
// Graphic Lab's sheet, printed on a canvas, laid over the whole frame: a sheet of paper held
// against the glass. vUv runs up the screen and the sheet's first row is its top, which is the flip
// three performs on the way into a canvas texture and this performs on the way out. The sheet is
// opaque — every edition floods it before it draws — so what comes back is colour and nothing else.
layout(set = 0, binding = 0) uniform sampler2D sheet;
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

void main() {
  fragColor = texture(sheet, vec2(vUv.x, 1.0 - vUv.y));
}
