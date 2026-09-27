#ifndef FOGVOL_GLSL
#define FOGVOL_GLSL
#include "/lib/voxel.glsl"

// Block light reaching the air, for the volumetric fog. shadowcomp_b traces
// rays out of every lamp through the voxel grid and stops them at the first
// occluder; every air cell a fog ray crosses on the way receives the ray's
// flux times the length crossed, and the ray's direction times the
// luminance of that. The sum over a cell is the lamp irradiance there,
// shadowed, falling off with distance by the ray count alone, and the mean
// direction the light travels in, its length against the luminance the
// share of the light that comes from one side. Deposits go to fixed-point
// counters here, three unsigned for the colour and three signed for the
// direction; shadowcomp_d folds them into a persistent pair of volumes,
// one written per frame parity, in the units of the direct term before
// LPV_EMISSION.

layout(std430, binding = 3) buffer FogAcc {
    uint v[];
} fogAcc;

int fogIndex(ivec3 c) { return ((c.z * VOXEL_SIZE + c.y) * VOXEL_SIZE + c.x) * 6; }

#endif