// What both of Wireframe's stages read.
layout(set = 0, binding = 0, std140) uniform WireframeUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uTime;
  float uBass;
  float uHigh;
  float uWarp;
  vec2 uTouch;
  vec3 uNear;
  vec3 uFar;
};
