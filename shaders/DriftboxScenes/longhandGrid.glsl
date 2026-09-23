// What both of Longhand's grid stages read.
layout(set = 0, binding = 0, std140) uniform LonghandGridUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  vec3 uColour;
};
