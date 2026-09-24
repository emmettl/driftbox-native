#version 450
// A page drawn onto a transparent target holds its colour already multiplied by its alpha: what
// straight alpha over nothing leaves. Divided out again here, so it can go over the frame as
// straight alpha, the one blend every backend has.
layout(set = 0, binding = 1) uniform sampler2D page;
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

void main() {
  vec4 colour = texture(page, vUv);
  if (colour.a <= 0.0) discard;
  fragColor = vec4(colour.rgb / colour.a, colour.a);
}
