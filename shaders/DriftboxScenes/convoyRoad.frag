#version 450
#extension GL_GOOGLE_include_directive : require
#include "convoyRoad.glsl"
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

void main() {
  vec3 ground = vec3(0.035, 0.075, 0.09);
  vec3 lineColour = vec3(0.13, 0.72, 0.68);

  // Uneven spacing compresses toward the horizon, giving the flat side view just enough
  // depth to feel like a cabinet landscape rather than a diagram.
  float away = pow(vUv.y, 1.65);
  float horizontal = 1.0 - smoothstep(0.035, 0.09, abs(fract(away * 8.0) - 0.5));
  float scroll = vUv.x * 22.0 + uTime * (1.7 + uBass * 2.2);
  float vertical = 1.0 - smoothstep(0.035, 0.085, abs(fract(scroll) - 0.5));
  float grid = max(horizontal * 0.6, vertical * (0.25 + away * 0.7));

  vec3 colour = ground + lineColour * grid * (0.34 + uHigh * 0.75);
  fragColor = vec4(colour, 1.0);
}
