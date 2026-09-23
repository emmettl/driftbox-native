// The whole of three's `LineBasicMaterial` and `MeshBasicMaterial` as Endless Convoy uses
// them: a position, a flat colour and an opacity. No lighting, no vertex colours, no
// size attenuation — none of those is switched on anywhere here.
//
// The opacity comes before the colour, not after it as in the Metal block: a scalar straight
// after a vec3 packs into the vec3's last four bytes, which a Swift struct cannot match.
layout(set = 0, binding = 0, std140) uniform ConvoyFlatUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uOpacity;
  vec3 uColour;
};
