#version 430
#include "/lib/settings.glsl"
#include "/lib/voxel.glsl"
#include "/lib/entity_tris.glsl"
#include "/lib/lights.glsl"
#include "/lib/bounce.glsl"
#include "/lib/near.glsl"
#define GUIDE_WRITE
#include "/lib/guide.glsl"
#define TERRAIN_HEAD_IMAGE
#include "/lib/terrain_tris.glsl"

// Grid step 2, see lib/grid_step.glsl. The bounce ray budget is split
// between this frame's lamps, the triangle lists are compacted, the bounce
// volume is copied B -> A, which the deferred pass samples, and the
// deposit counters are zeroed for shadowcomp_b. Eight image uniforms is
// the limit of a stage; the reset flags are cleared by shadowcomp_c.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
const ivec3 workGroups = ivec3(16, 16, 16);

layout(r32ui)   uniform uimage3D voxelImg;
layout(rgba16f) uniform readonly  image3D bounceImgB;
layout(rgba16f) uniform writeonly image3D bounceImgA;
layout(r32ui)   uniform writeonly uimage3D bounceAccR;
layout(r32ui)   uniform writeonly uimage3D bounceAccG;
layout(r32ui)   uniform writeonly uimage3D bounceAccB;

#define STEP_RAY_BUDGET
#define STEP_LAMP_BINS
#define STEP_GUIDE
#define STEP_NEAR_MASK
#define STEP_COMPACT_TRIS
#define STEP_BIN_ENTITIES
#define STEP_BOUNCE_COPY
#include "/lib/grid_step.glsl"
