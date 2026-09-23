// What both of Web's stages read.
layout(set = 0, binding = 0, std140) uniform WebUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  // One per lane, in .x: std140 spaces a float array's elements sixteen bytes apart anyway, and
  // Swift can only match that as an array of vec4.
  vec4 uBands[16];
  float uTime;
  float uBass;
  float uHigh;
  float uWarp;
  vec3 uEye;
  vec3 uRay;
};
