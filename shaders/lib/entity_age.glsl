#ifndef ENTITY_AGE_GLSL
#define ENTITY_AGE_GLSL
#include "/lib/voxel.glsl"

// Frames an entity cell is held past its last sighting, one uint per voxel
// in two sets by frame parity. The first LPV step writes this frame's set
// and reads last frame's at the shifted position. Only the exact value
// written last frame counts, so whatever the buffer held at start is
// ignored.

const int ENTITY_AGE_CELLS = VOXEL_SIZE * VOXEL_SIZE * VOXEL_SIZE;

layout(std430, binding = 5) buffer EntityAge {
    uint age[];
} entityAge;

int entityAgeIndex(int set, ivec3 c) {
    return set * ENTITY_AGE_CELLS + (c.z * VOXEL_SIZE + c.y) * VOXEL_SIZE + c.x;
}

#endif

