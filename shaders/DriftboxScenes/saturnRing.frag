#version 450
layout(location = 0) in float vShine;
layout(location = 1) in float vRadius;
layout(location = 2) in vec2 vPointCoord;
layout(location = 0) out vec4 fragColor;

void main() {
  vec2 d = vPointCoord - 0.5;
  if (dot(d, d) > 0.25) discard;
  // Icier than the planet, and paler further out.
  vec3 colour = mix(vec3(0.72, 0.66, 0.55), vec3(0.86, 0.90, 1.0), vRadius);
  fragColor = vec4(colour * vShine, vShine * 0.85);
}
