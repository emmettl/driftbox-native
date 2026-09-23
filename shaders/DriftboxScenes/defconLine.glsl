// What both of Defcon's flat line stages read: one colour at one opacity. The opacity comes
// before the colour, not after it as Metal had it: a scalar straight after a vec3 is a layout
// Swift cannot match.
layout(set = 0, binding = 0, std140) uniform DefconLineUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uOpacity;
  vec3 uColour;
};
