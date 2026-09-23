#version 450
#extension GL_GOOGLE_include_directive : require
#include "web.glsl"
// The web: sixteen lanes of spokes and the rings closing them into cells, a well narrowing to a
// point, each lane swelling with its own band and all of it falling into a finger.
layout(location = 0) in vec3 aPosition;
layout(location = 1) in float aLane;
layout(location = 2) in float aRing;
layout(location = 0) out float vLane;
layout(location = 1) out float vRing;
layout(location = 2) out float vHeat;
layout(location = 3) out float vHole;

void main() {
  vec3 pos = aPosition;

  // How loud this lane is.
  float heat = uBands[int(aLane + 0.5)].x;
  // The lane swells outward with its own band. This is the readout: a loud lane is
  // physically wider than a quiet one, so the web takes the shape of the mix.
  pos.xy *= 1.0 + heat * 0.55 * aRing;
  // The whole well pumps on the low end.
  pos.xy *= 1.0 + uBass * 0.16;

  // A finger is a black hole, and the web falls into it. In polar coordinates around
  // the finger, because the two things that make this read as gravity — everything
  // falling inward, and the near stuff swirling harder than the far — are a radius term
  // and an angle term, one line each. The hole is the whole LINE OF SIGHT through the
  // fingertip, not a point on one plane: this web is thirty-four units deep.
  float along = (pos.z - uEye.z) / uRay.z;
  vec2 finger = uEye.xy + uRay.xy * along;
  vec2 rel = pos.xy - finger;
  float r = length(rel);
  float angle = atan(rel.y, rel.x);
  // Infall, softened at the bottom so the pull is finite at the centre, and capped just
  // short of the full distance so nothing crosses the middle and comes out the far side.
  float pull = min(uWarp * 26.0 / (r + 2.2), r * 0.96);
  float sunk = r - pull;
  // Frame dragging: rotation rises sharply close in, so the web winds into a spiral near
  // the finger and is barely disturbed at the rim.
  angle += uWarp * 5.2 / (r + 1.8);
  pos.xy = finger + vec2(cos(angle), sin(angle)) * sunk;
  // And a funnel: the geometry nearest the hole is dragged away down the well.
  pos.z -= uWarp * 14.0 * exp(-r * r * 0.016);

  vLane = aLane;
  vRing = aRing;
  vHeat = heat;
  // How hard this vertex was compressed. Light piles up where the lines bunch, which is
  // the accretion ring, and it costs nothing because the number is already computed.
  vHole = pull / max(r, 0.001);
  gl_Position = projectionMatrix * modelViewMatrix * vec4(pos, 1.0);
}
