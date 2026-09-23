#version 450
layout(set = 0, binding = 0, std140) uniform FlatUniforms {
  mat4 transform;
  vec4 colour;
} u;
layout(location = 0) out vec4 fragColor;

void main() {
  fragColor = u.colour;
}
