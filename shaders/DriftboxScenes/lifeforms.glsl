// What both of Lifeforms' stages read: one body's worth, set again before each body is drawn.
layout(set = 0, binding = 0, std140) uniform LifeformsUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  mat4 normalMatrix;
  float uTime;
  float uBass;
  float uHigh;
  float uWarp;
  float uSeed;
  vec3 uPull;
  vec3 uInner;
  vec3 uRim;
};
