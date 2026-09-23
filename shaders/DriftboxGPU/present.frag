#version 450
layout(set = 0, binding = 1) uniform sampler2D frame;
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

void main() {
  fragColor = vec4(texture(frame, vUv).rgb, 1.0);
}
