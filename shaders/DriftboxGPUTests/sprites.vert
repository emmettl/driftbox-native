#version 450
// A sprite: an instanced quad, since no backend here may size a point. Its centre and colour step
// per instance; its corner comes from the vertex index.
layout(set = 0, binding = 0, std140) uniform SpriteUniforms {
  vec2 radius;
} u;
layout(location = 0) in vec2 aCentre;
layout(location = 1) in vec4 aColour;
layout(location = 0) out vec2 vCorner;
layout(location = 1) out vec4 vColour;

void main() {
  vec2 corners[6] = vec2[](vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, 1.0));
  vCorner = corners[gl_VertexIndex];
  vColour = aColour;
  gl_Position = vec4(aCentre + vCorner * u.radius, 0.0, 1.0);
}
