layout(set = 0, binding = 0, std140) uniform SaturnRingUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uTime;
  float uBass;
  float uHat;
  float uWarp;
  float uPixelRatio;
};
