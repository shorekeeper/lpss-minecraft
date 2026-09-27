#version 430
#include "/lib/settings.glsl"
#include "/lib/voxel.glsl"
#include "/lib/entity_tris.glsl"
#include "/lib/lights.glsl"
#include "/lib/terrain_tris.glsl"
#include "/lib/entity_age.glsl"
#include "/lib/bounce.glsl"
#include "/lib/history.glsl"

// Grid step 1, see lib/grid_step.glsl. The bounce volume is folded
// A (shifted by camera movement) -> B with the confidence weight of
// lib/history.glsl.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
const ivec3 workGroups = ivec3(16, 16, 16);

layout(r32ui)   uniform uimage3D voxelImg;
layout(rgba16f) uniform readonly  image3D bounceImgA;
layout(rgba16f) uniform writeonly image3D bounceImgB;
layout(r32ui)   uniform readonly uimage3D bounceAccR;
layout(r32ui)   uniform readonly uimage3D bounceAccG;
layout(r32ui)   uniform readonly uimage3D bounceAccB;
layout(r8ui)    uniform readonly uimage3D resetImgA;
layout(r8ui)    uniform readonly uimage3D resetImgB;

#define STEP_SHIFT
#define STEP_LISTS
#define STEP_ENTITY_HOLD
#define STEP_BOUNCE_BLEND
#include "/lib/grid_step.glsl"
