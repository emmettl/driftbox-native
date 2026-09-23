#version 450
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

void main() {
  fragColor = vec4(vUv, 0.0, 1.0);
}
