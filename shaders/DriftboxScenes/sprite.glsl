// Sprites: what Metal draws as a point with a size, drawn on every backend as an instanced quad,
// since Direct3D's points are a pixel wide whatever they are told. A sprite's own data steps per
// instance, and its six vertices are the quad's corners. The geometry scenes' base sets this
// block before a scene draws anything, at a binding of its own so a scene's blocks never meet it.
layout(set = 0, binding = 4, std140) uniform SpriteUniforms {
  // The target's size in pixels: sprites are sized in pixels, as points are.
  vec2 uViewport;
};

const vec2 spriteCorners[6] = vec2[](vec2(-1, -1), vec2(1, -1), vec2(1, 1), vec2(-1, -1), vec2(1, 1), vec2(-1, 1));

// This vertex's corner of a sprite at `clip`, `size` pixels across, and where on the sprite it
// is as Metal's `point_coord` has it: 0...1 from the top left.
vec4 spriteCorner(vec4 clip, float size, out vec2 pointCoord) {
  vec2 corner = spriteCorners[gl_VertexIndex];
  pointCoord = vec2(corner.x, -corner.y) * 0.5 + 0.5;
  return clip + vec4(corner * size / uViewport * clip.w, 0.0, 0.0);
}
