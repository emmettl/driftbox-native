#version 450
#extension GL_GOOGLE_include_directive : require
#include "cloudsPuff.glsl"
#include "sprite.glsl"
// A cloud's puffs: soft round sprites clustered into a fat lens, squashed on the kick. A puff is
// an instance.
layout(location = 0) in vec3 aPosition;
layout(location = 1) in float aCloud;
layout(location = 2) in float aSize;
layout(location = 3) in float aTop;
layout(location = 0) out float vTop;
layout(location = 1) out float vShade;
layout(location = 2) out vec2 vPointCoord;

void main() {
  // Which cloud this puff belongs to. The web unrolls a loop over all seven slots here,
  // because older GLSL will not index a uniform array with a value that arrived on an
  // attribute; this one will, so it is one fetch.
  vec4 cloud = uClouds[int(aCloud + 0.5)];

  // Squash and stretch. The oldest trick in animation: a cartoon body keeps its volume,
  // so anything that flattens also has to widen. Driven by the kick, it makes the whole
  // sky bounce without a single thing moving from where it is.
  float squash = cloud.w;
  vec3 pos = aPosition;
  pos.y *= squash;
  pos.x /= squash;
  pos += cloud.xyz;

  vTop = aTop;
  // Lit from where the sun is, roughly: the tops of the puffs are white and the
  // undersides go blue-grey. Real enough at this size, and it is what makes a circle read
  // as a lump rather than as a dot.
  vShade = 0.55 + vTop * 0.45;

  vec4 view = modelViewMatrix * vec4(pos, 1.0);
  float size = aSize * uPixelRatio * (300.0 / max(1.0, -view.z));
  gl_Position = spriteCorner(projectionMatrix * view, size, vPointCoord);
}
