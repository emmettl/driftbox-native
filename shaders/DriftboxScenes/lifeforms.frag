#version 450
#extension GL_GOOGLE_include_directive : require
#include "lifeforms.glsl"
layout(location = 0) in vec3 vNormal;
layout(location = 1) in vec3 vView;
layout(location = 2) in float vBulge;
layout(location = 0) out vec4 fragColor;

void main() {
  // Fresnel: bright at the silhouette, near-transparent facing you. It is what makes a
  // translucent body read as volume rather than as a flat coloured disc.
  float fres = pow(1.0 - abs(dot(normalize(vNormal), normalize(vView))), 2.2);
  vec3 colour = mix(uInner, uRim, clamp(fres + vBulge * 0.5, 0.0, 1.0));
  float alpha = clamp(fres * 0.9 + 0.06 + uBass * 0.12, 0.0, 1.0);
  fragColor = vec4(colour * (0.8 + uBass * 0.9), alpha);
}
