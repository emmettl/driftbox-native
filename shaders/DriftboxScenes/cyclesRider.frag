#version 450
layout(location = 0) in vec3 vColour;
// Unread: a Metal point is a square with no edge to shade, and so is the sprite.
layout(location = 1) in vec2 vPointCoord;
layout(location = 0) out vec4 fragColor;

void main() {
  fragColor = vec4(vColour, 1.0);
}
