layout(set = 0, binding = 0, std140) uniform SaturnPlanetUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uTime;
  float uBass;
  float uHigh;
  float uPixelRatio;
  // xyz where an impact landed, w its age in seconds; negative means the slot is empty.
  vec4 uImpacts[10];
};
