#version 450
layout(location = 0) in float vTop;
layout(location = 1) in float vShade;
layout(location = 2) in vec2 vPointCoord;
layout(location = 0) out vec4 fragColor;

void main() {
  vec2 d = vPointCoord - 0.5;
  float r = length(d);
  if (r > 0.5) discard;

  // A soft edge, but not too soft — a cartoon cloud has an edge you could draw round.
  // Fading it out over the last fifth of the radius gives a lump rather than a smudge.
  float alpha = 1.0 - smoothstep(0.30, 0.5, r);

  // Shaded within the puff as well as between them, so each lump is round.
  float lift = 1.0 - smoothstep(-0.1, 0.45, d.y);
  vec3 white = vec3(1.0, 0.99, 0.97);
  vec3 shadow = vec3(0.66, 0.74, 0.86);
  vec3 colour = mix(shadow, white, clamp(vShade * 0.55 + lift * 0.6, 0.0, 1.0));

  fragColor = vec4(colour, alpha);
}
