#version 450
layout(location = 0) in vec3 vColour;
layout(location = 1) in float vGlow;
layout(location = 2) in vec2 vPointCoord;
layout(location = 0) out vec4 fragColor;

void main() {
  // Square, not round: this is a pixel. The bevel is the modern part — a light top-left edge
  // and a dark bottom-right one, so each cell reads as a little block with a thickness rather
  // than as a flat swatch. That is the whole "extruded sprite" idea in four lines of shader.
  vec2 p = vPointCoord;
  float lit = smoothstep(0.42, 0.06, max(p.x, p.y));
  float shade = smoothstep(0.58, 0.94, max(1.0 - p.x, 1.0 - p.y));
  vec3 colour = vColour * (0.82 + lit * 0.5 - shade * 0.28) + vColour * vGlow;
  fragColor = vec4(colour, 1.0);
}
