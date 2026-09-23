#version 450
#extension GL_GOOGLE_include_directive : require
#include "machineSolid.glsl"
#include "machine.glsl"
layout(location = 0) in vec3 vWorld;
layout(location = 1) in vec3 vNormal;
layout(location = 2) in vec3 vColour;
layout(location = 3) in float vRoughness;
layout(location = 4) in float vMetalness;
layout(location = 5) in float vEmissive;
layout(location = 6) in float vFogDepth;
layout(location = 0) out vec4 fragColor;

void main() {
  vec3 n = normalize(vNormal);
  vec3 v = normalize(uEye - vWorld);
  float roughness = vRoughness;
  // Metal has no diffuse and tints its own reflection; a dielectric reflects four percent
  // of everything and keeps its colour in the diffuse lobe.
  vec3 diffuse = vColour * (1.0 - vMetalness);
  vec3 f0 = mix(vec3(0.04), vColour, vMetalness);

  vec3 lit = uAmbient * diffuse * machineRecipPi;

  vec3 l = uSunDirection;
  float dotNL = clamp(dot(n, l), 0.0, 1.0);
  lit += dotNL * uSun * (diffuse * machineRecipPi + machineSpecular(f0, roughness, n, v, l));

  vec3 toLamp = uLampPosition - vWorld;
  float reach = length(toLamp);
  l = toLamp / max(reach, 1e-4);
  // Inverse square, windowed to nothing at the light's `distance` so it cannot light the
  // far end of the belt through the press.
  float window = clamp(1.0 - pow(reach / uLampRange, 4.0), 0.0, 1.0);
  float falloff = window * window / max(reach * reach, 0.01);
  dotNL = clamp(dot(n, l), 0.0, 1.0);
  lit += dotNL * uLamp * falloff
    * (diffuse * machineRecipPi + machineSpecular(f0, roughness, n, v, l));

  // The billet glows from inside while it is being struck, which is the one place in the
  // scene where a surface is a source rather than a receiver.
  lit += uGlow * vEmissive;

  fragColor = vec4(machineFog(machineEncode(machineTonemap(lit)), vFogDepth), 1.0);
}
