#version 450
// Pulse: a dark field that breathes with the level, a ring that leaps out on every kick, a horizon
// that flickers on hats, and a 303 note as a rising line. The fallback scene — everything a song can
// have, in a form nobody will mistake for the real one.
layout(set = 0, binding = 0, std140) uniform PulseUniforms {
  float time;
  float peak;
  // The last kick, snare, hat and note: how long ago, in seconds, or a large number.
  float sinceKick;
  float sinceSnare;
  float sinceHat;
  float sinceNote;
  float notePitch;  // 0...1 across the 303's range
  vec2 touch;       // or (-1, -1)
  vec2 size;
  vec3 accent;
} u;
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

void main() {
  vec2 p = vUv * 2.0 - 1.0;
  p.x *= u.size.x / u.size.y;
  float r = length(p);

  vec3 colour = vec3(0.02, 0.02, 0.03) + u.accent * 0.04 * u.peak;

  // The kick: the whole field blooms and a ring expands from the centre, both fading.
  float kick = exp(-u.sinceKick * 3.0);
  float ring = smoothstep(0.03, 0.0, abs(r - u.sinceKick * 2.4)) * kick;
  colour += u.accent * (ring * 1.5 + kick * 0.3 * (1.0 - r * 0.5));

  // The snare: a flash across the whole field.
  colour += vec3(0.6, 0.55, 0.5) * exp(-u.sinceSnare * 12.0) * 0.35;

  // Hats: sparkle along a horizon.
  float horizon = smoothstep(0.01, 0.0, abs(p.y + 0.35)) * exp(-u.sinceHat * 20.0);
  colour += vec3(0.9, 0.9, 1.0) * horizon * 0.6;

  // A note: a line whose height is its pitch, holding while it sounds.
  float noteY = -0.8 + u.notePitch * 1.4;
  float note = smoothstep(0.02, 0.0, abs(p.y - noteY)) * exp(-u.sinceNote * 2.0);
  colour += u.accent.zyx * note * 0.8;

  // The pad's cursor.
  if (u.touch.x >= 0.0) {
    vec2 t = u.touch * 2.0 - 1.0;
    t.x *= u.size.x / u.size.y;
    colour += u.accent * smoothstep(0.08, 0.0, length(p - t)) * 0.8;
  }

  // A vignette, so the edges stay dark whatever happens.
  colour *= 1.0 - smoothstep(0.9, 1.6, r) * 0.8;
  fragColor = vec4(colour, 1.0);
}
