#version 450
#extension GL_GOOGLE_include_directive : require
#include "stillwaterWater.glsl"
#include "sprite.glsl"
// Stillwater's surface: points scattered across a black water plane, which a hit drops a ring
// on that travels outward and dies. Each point is a sprite rather than a Metal point, so it is
// the same size on every backend.
layout(location = 0) in vec3 aPosition;
layout(location = 0) out float vLift;
layout(location = 1) out float vFade;
layout(location = 2) out vec2 vPointCoord;

void main() {
  vec3 pos = aPosition;
  // The idle surface: two long, slow swells crossing. Barely visible, but a dead flat
  // plane of points reads as a texture rather than as water, and the rings landing on
  // something that is already alive is most of what sells them.
  float swell = sin(pos.x * 0.055 + uTime * 0.28) * 0.34 + sin(pos.z * 0.041 - uTime * 0.19) * 0.28;
  pos.y += swell * (0.6 + uBass * 1.4);

  float lift = 0.0;
  for (int i = 0; i < 12; i++) {
    vec4 r = uRipples[i];
    if (r.w <= 0.0) continue;
    float d = distance(pos.xz, r.xy);
    // Where the front has reached by now, and a narrow band around it. Outside the band
    // the water has not been touched yet or has already settled — which is what makes
    // this a travelling ring and not the whole pond bobbing.
    float front = r.z * 15.0;
    float band = exp(-(d - front) * (d - front) * 0.05);
    lift += sin((d - front) * 1.1) * band * r.w * exp(-r.z * 0.55);
  }
  pos.y += lift;

  // A finger drags a standing swell around with it, so touching the water does the same
  // kind of thing a hit does rather than warping the whole plane.
  vec2 finger = vec2((uTouch.x - 0.5) * 90.0, (0.5 - uTouch.y) * 90.0 - 20.0);
  float fd = distance(pos.xz, finger);
  pos.y += exp(-fd * fd * 0.004) * uWarp * 3.2 * (0.6 + sin(fd * 0.5 - uTime * 5.0) * 0.4);

  vec4 view = modelViewMatrix * vec4(pos, 1.0);
  // Points shrink with distance like anything else would, and the far edge of the plane
  // has to fade out or the horizon is a hard line of dots.
  float dist = -view.z;
  float size = clamp(90.0 / dist, 1.0, 5.0) * uPixel;
  vLift = lift;
  vFade = 1.0 - smoothstep(45.0, 130.0, dist);
  gl_Position = spriteCorner(projectionMatrix * view, size, vPointCoord);
}
