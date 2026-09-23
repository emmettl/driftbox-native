// What Machine's two programs both shade with: a small standard material's direct lighting,
// three's ACES filmic tone mapping, the sRGB encode and the fog mixed in after both. What it
// approximates, and why, is written out in `MachineScene.swift`, on `solidPipeline`.

const float machineRecipPi = 0.31830988618379069;
// `#100e0b`, the background, in display values: three's fog is mixed in after the tone mapping
// and the encode, so the far end of the belt fades to exactly the background.
const vec3 machineFogColour = vec3(0.0627451, 0.05490196, 0.04313725);

vec3 machineSpecular(vec3 f0, float roughness, vec3 n, vec3 v, vec3 l) {
  float alpha = roughness * roughness;
  float a2 = alpha * alpha;
  vec3 h = normalize(l + v);
  float dotNL = clamp(dot(n, l), 0.0, 1.0);
  float dotNV = clamp(dot(n, v), 0.0, 1.0);
  float dotNH = clamp(dot(n, h), 0.0, 1.0);
  float dotVH = clamp(dot(v, h), 0.0, 1.0);
  // Smith's height-correlated visibility, which already carries the 1/(4 dotNL dotNV).
  float gv = dotNL * sqrt(a2 + (1.0 - a2) * dotNV * dotNV);
  float gl = dotNV * sqrt(a2 + (1.0 - a2) * dotNL * dotNL);
  float visibility = 0.5 / max(gv + gl, 1e-6);
  float denom = dotNH * dotNH * (a2 - 1.0) + 1.0;
  float distribution = machineRecipPi * a2 / max(denom * denom, 1e-6);
  vec3 fresnel = f0 + (1.0 - f0) * pow(clamp(1.0 - dotVH, 0.0, 1.0), 5.0);
  return fresnel * (visibility * distribution);
}

vec3 machineTonemap(vec3 colour) {
  mat3 toAces = mat3(
    vec3(0.59719, 0.07600, 0.02840), vec3(0.35458, 0.90834, 0.13383),
    vec3(0.04823, 0.01566, 0.83777));
  mat3 fromAces = mat3(
    vec3(1.60475, -0.10208, -0.00327), vec3(-0.53108, 1.10813, -0.07276),
    vec3(-0.07367, -0.00605, 1.07602));
  vec3 v = toAces * (colour / 0.6);
  vec3 a = v * (v + 0.0245786) - 0.000090537;
  vec3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
  return clamp(fromAces * (a / b), 0.0, 1.0);
}

vec3 machineEncode(vec3 colour) {
  vec3 curve = pow(colour, vec3(0.41666)) * 1.055 - 0.055;
  return mix(curve, colour * 12.92, lessThanEqual(colour, vec3(0.0031308)));
}

vec3 machineFog(vec3 colour, float depth) {
  return mix(colour, machineFogColour, smoothstep(14.0, 31.0, depth));
}
