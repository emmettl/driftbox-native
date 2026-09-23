// What Longhand's ink reads — the tubes and the two nibs alike, which differ only in how the
// shape is placed: both programs include this block, as the Metal scene's two vertex functions
// shared one struct. The scalars are ahead of the colours, where Metal had them after, since a
// scalar straight after a vec3 has no Swift layout.
layout(set = 0, binding = 0, std140) uniform LonghandInkUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uRadius;
  float uOpacity;
  vec3 uOrigin;
  vec3 uColour;
};
