#ifndef HISTORY_GLSL
#define HISTORY_GLSL
#include "/lib/settings.glsl"
#include "/lib/voxel.glsl"

// Temporal weighting of the bounce and fog volumes. The alpha channel of a
// volume holds the number of frames its cell has accumulated; a fresh cell
// takes the new frame whole and the weight falls as 1 / (n + 1) down to the
// pack's floor. shadowcomp_c compares the classification of every voxel
// with last frame's and flags the cells within RESET_RADIUS of a change,
// and the cells within LPV_RANGE of a lamp that entered or left the light
// list; a flagged cell starts its count over when it is next folded. The
// classification and the flags live in image pairs by frame parity: the
// flags are written by shadowcomp_c, read by the fog fold the same frame
// and the bounce fold the next; shadowcomp_c clears the set the bounce
// fold has read while it writes the other.

const int RESET_RADIUS = 2;
const float HISTORY_CAP = 1024.0;

const uint CLASS_FULL = 1u;
const uint CLASS_PARTIAL = 2u;
const uint CLASS_LEAVES = 4u;
const uint CLASS_EMITTER = 8u;

// What of a voxel matters to the light. Entity boxes move every frame and
// are left out.
uint voxelClass(uint v) {
    uint c = 0u;
    if (voxelFull(v)) c |= CLASS_FULL;
    else if (voxelSolid(v) && voxelPartial(v)) c |= CLASS_PARTIAL;
    if (voxelLeaves(v)) c |= CLASS_LEAVES;
    if (voxelEmission(v) > 0) c |= CLASS_EMITTER;
    return c;
}

int historySet(int frame) { return frame & 1; }

// Frames accumulated, as stored in a volume's alpha; a value that came in
// unwritten counts as none
float historyCount(float a) {
    if (!(a >= 0.0)) return 0.0;
    return min(a, HISTORY_CAP);
}

float historyWeight(float n, float floorWeight) {
    return max(floorWeight, 1.0 / (n + 1.0));
}

#endif
