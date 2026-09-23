// What both of Longhand's dust stages read. The scalars are ahead of the colours, where Metal
// had them after, since a scalar straight after a vec3 has no Swift layout.
layout(set = 0, binding = 0, std140) uniform LonghandDustUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uSize;
  float uOpacity;
  float uFogNear;
  float uFogFar;
  vec3 uColour;
  vec3 uFogColour;
};
