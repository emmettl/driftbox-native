#version 450
#extension GL_GOOGLE_include_directive : require
#include "trenchStation.glsl"
// The trench run's station: the hull, the groove cut into it, the clutter bolted to its walls and
// the dish, in one line list.
layout(location = 0) in vec3 aPosition;
layout(location = 1) in float aKind;
layout(location = 0) out float vFade;
layout(location = 1) out float vKind;

void main() {
  vec3 pos = aPosition;

  // The station breathes on the low end, radially — on a ring, "wider" means further from
  // the axis, so x and z move together and the groove stays a groove.
  //
  // In WORLD UNITS, not as a fraction of the radius, and that is the whole point. As a
  // fraction it was 1.2%, which was four units when the station had a radius of 420 and is
  // thirty-eight now that it has one of 3200 — while the ship still flies sixteen units
  // above the floor. Any kick over a third of full scale lifted the floor straight through
  // the camera. A proportional pulse does not survive its subject being scaled.
  float here = max(1.0, length(pos.xz));
  pos.xz *= 1.0 + (uBass * 2.5) / here;

  // Banking. The trench leans away from the finger, which is what a ship pulling sideways
  // would look like from inside it.
  pos.y -= (uTouch.y - 0.5) * uWarp * 6.0;

  vec4 seen = modelViewMatrix * vec4(pos, 1.0);
  gl_Position = projectionMatrix * seen;

  // Fog by actual distance, which is only possible because the geometry stands still.
  // Distance rather than forward depth: the far side of the enormous ring can share the
  // near floor's depth and otherwise piles its machinery up into a bright horizon.
  float dist = length(seen.xyz);
  vFade = 1.0 - smoothstep(uFog.x, uFog.y, dist);
  vKind = aKind;
}
