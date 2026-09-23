// What both of Machine's spark stages read. The scalars are ahead of the colour, where Metal
// had them after it, since a scalar straight after a vec3 has no Swift layout.
layout(set = 0, binding = 0, std140) uniform MachineSparkUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uScale;
  float uOpacity;
  vec3 uColour;
};
