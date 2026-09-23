#version 450
#extension GL_GOOGLE_include_directive : require
#include "surface.glsl"
// Frost's cards: instanced quads, each placed by its own matrix, which steps per instance.
layout(location = 0) in vec4 aInstance0;
layout(location = 1) in vec4 aInstance1;
layout(location = 2) in vec4 aInstance2;
layout(location = 3) in vec4 aInstance3;
layout(location = 0) out vec2 vUv;
layout(location = 1) out vec2 vPage;
layout(location = 2) out float vSeed;

void main() {
  mat4 instanceMatrix=mat4(aInstance0,aInstance1,aInstance2,aInstance3);
  vec2 position=cardCorners[gl_VertexIndex];
  vUv=(position+1.0)*0.5;
  vSeed=instanceMatrix[3].z;
  vec4 p=instanceMatrix*vec4(position,0.0,1.0);
  vPage=p.xy;
  gl_Position=vec4(p.x*2.0/(uSize.x/uSize.y),(p.y-0.5)*2.0,0.0,1.0);
}
