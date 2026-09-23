#version 450
#extension GL_GOOGLE_include_directive : require
#include "cubik.glsl"
// Cubik: one cube, instanced across a 27 by 27 floor. Concentric rings follow logarithmic
// frequency bands while the low end sends a second wave through the whole field.
layout(location = 0) in vec3 aPosition;
layout(location = 1) in vec3 aNormal;
// Per instance: where on the grid, which band, which ink.
layout(location = 2) in vec2 aGrid;
layout(location = 3) in float aBand;
layout(location = 4) in float aInk;
layout(location = 0) out vec3 vNormal;
layout(location = 1) out float vInk;
layout(location = 2) out float vEnergy;
layout(location = 3) out float vDepth;

void main() {
  vec3 position = aPosition;

  vec2 centre = (uTouch - 0.5) * vec2(19.44, -19.44) * uWarp;
  float radius = length(aGrid - centre);
  float lane = uBands[int(aBand + 0.5)].x;

  // Two waves: the spectrum makes persistent rings, the kick sends a sharp front
  // outwards. The latter moves faster when the record gets louder.
  float standing = 0.5 + 0.5 * sin(radius * 0.92 - uTime * 2.1 + aBand * 0.33);
  float travelling = max(0.0, sin(radius * 1.32 - uTime * (3.2 + uBass * 1.2)));
  // A broad crest reads as a wave passing through the field. A fifth-power spike made
  // each row switch on and off like a bank of camera flashes.
  travelling = pow(travelling, 3.0);
  float energy = lane * (0.34 + standing * 0.55) + uBass * travelling * 0.62;
  // Full-scale analysers are common once the limiter is working, so the visual range is
  // compressed here: a loud chorus is still a landscape rather than a solid wall.
  energy = min(1.12, energy);

  // A little height while silent keeps this a field of objects rather than a checkerboard.
  float height = 0.22 + energy * 2.15;
  vec3 pos = position;
  pos.y *= height;
  pos.y += height * 0.5;
  // The distorted synth bends the towers rather than merely making them taller. Since the
  // displacement grows up the cube, the feet remain locked to the grid.
  float bend = sin(aGrid.x * 0.71 + aGrid.y * 0.43 + uTime * 2.7);
  pos.x += position.y * bend * energy * 0.22;
  pos.z += position.y * cos(bend * 2.2 + uTime) * energy * 0.13;
  pos.x += aGrid.x * 0.64;
  pos.z += aGrid.y * 0.64;

  vec4 view = modelViewMatrix * vec4(pos, 1.0);
  gl_Position = projectionMatrix * view;
  vNormal = normalize((normalMatrix * vec4(aNormal, 0.0)).xyz);
  vInk = aInk;
  vEnergy = energy;
  vDepth = clamp((-view.z - 7.0) / 24.0, 0.0, 1.0);
}
