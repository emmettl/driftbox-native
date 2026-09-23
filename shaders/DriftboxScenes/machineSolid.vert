#version 450
#extension GL_GOOGLE_include_directive : require
#include "machineSolid.glsl"
// Machine's parts: each shape drawn once, with the parts as instances. A part is where it is
// and the four numbers its material is, stepping per instance.
layout(location = 0) in vec3 aPosition;
layout(location = 1) in vec3 aNormal;
layout(location = 2) in vec4 aModel0;
layout(location = 3) in vec4 aModel1;
layout(location = 4) in vec4 aModel2;
layout(location = 5) in vec4 aModel3;
layout(location = 6) in vec4 aTurn0;
layout(location = 7) in vec4 aTurn1;
layout(location = 8) in vec4 aTurn2;
layout(location = 9) in vec4 aTurn3;
layout(location = 10) in vec3 aColour;
layout(location = 11) in float aRoughness;
layout(location = 12) in float aMetalness;
layout(location = 13) in float aEmissive;
layout(location = 0) out vec3 vWorld;
layout(location = 1) out vec3 vNormal;
layout(location = 2) out vec3 vColour;
layout(location = 3) out float vRoughness;
layout(location = 4) out float vMetalness;
layout(location = 5) out float vEmissive;
layout(location = 6) out float vFogDepth;

void main() {
  mat4 model = mat4(aModel0, aModel1, aModel2, aModel3);
  mat4 turn = mat4(aTurn0, aTurn1, aTurn2, aTurn3);
  vec4 world = model * vec4(aPosition, 1.0);
  vec4 view = modelViewMatrix * world;

  gl_Position = projectionMatrix * view;
  vWorld = world.xyz;
  // Lit in world space rather than in view space as three does, because the lights are
  // outside the group that turns and this way neither they nor the shader have to know it.
  vNormal = normalize((turn * vec4(aNormal, 0.0)).xyz);
  vColour = aColour;
  // three's own floor: below this the specular lobe is narrower than a pixel and aliases.
  vRoughness = max(aRoughness, 0.0525);
  vMetalness = aMetalness;
  vEmissive = aEmissive;
  vFogDepth = -view.z;
}
