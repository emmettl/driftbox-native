#version 450
layout(location = 0) in vec2 vCorner;
layout(location = 1) in vec4 vColour;
layout(location = 0) out vec4 fragColor;

void main() {
  // What point sprites' gl_PointCoord would give, and a round one cut from it.
  if (length(vCorner) > 1.0) discard;
  fragColor = vColour;
}
