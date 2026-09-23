// What both of Sunset's floor stages read.
layout(set = 0, binding = 0, std140) uniform SunsetGridUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uTime;
  float uBass;
  float uHigh;
  float uWarp;
  float uSpread;
  vec2 uTouch;
  vec3 uNear;
  vec3 uFar;
};
