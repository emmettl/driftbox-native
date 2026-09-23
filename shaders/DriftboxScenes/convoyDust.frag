#version 450
layout(location = 0) in float vLife;
layout(location = 1) in vec2 vPointCoord;
layout(location = 0) out vec4 fragColor;

void main() {
  vec2 p = vPointCoord - 0.5;
  if (dot(p, p) > 0.25) discard;
  fragColor = vec4(0.95, 0.72, 0.36, vLife);
}
