// What both of Stillwater's water stages read.
layout(set = 0, binding = 0, std140) uniform StillwaterWaterUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uTime;
  float uBass;
  float uHigh;
  float uWarp;
  float uPixel;
  vec2 uTouch;
  // Each ring is (x, z, age, strength); a dead one has strength 0 and contributes nothing,
  // so expiry needs no branching in the shader.
  vec4 uRipples[12];
};
