#ifndef LIGHTS_GLSL
#define LIGHTS_GLSL
#include "/lib/settings.glsl"
#include "/lib/lamp.glsl"

// Emitting voxels of the grid, gathered by the first grid step each frame
// into one of two sets alternating by frame parity, read by the deferred
// pass the same frame. Each entry is the grid index and the packed voxel.
// The second grid step splits the bounce ray budget between the lamps of
// the frame's set, see lightsBudget; shadowcomp_b reads the split the same
// frame, so it is kept once.
//
// The list holds every emitter of the grid, lava in the caves below
// included, while a surface reaches a handful of them. The second grid
// step therefore fills bins of LAMP_BIN blocks a side, one thread per bin
// walking the list and keeping the LAMP_BIN_MAX lamps of the highest
// strength over squared distance to the bin, ties broken by a hash of
// the lamp's position; a pixel walks the bin it lies in. Since the list
// itself is ordered by atomics and differs every frame, the bin must not
// depend on that order, or a full bin flickers. Filled and read the same
// frame, so one set suffices.
//
// The other set is the previous frame's list, which shadowcomp_c compares
// against to find lamps that entered or left; it is cleared by
// shadowcomp_d, after that comparison and before the next frame fills it.
//
// A lamp's share of the bounce budget is fixed when it is added, by the
// thread of its voxel: strength over the squared distance to the camera,
// scaled down to BUDGET_HIDDEN when the straight line to the camera runs
// through full cubes, so lava in the caves does not starve the lamps at
// the surface.

const int LIGHTS_MAX = 512;
const int BUDGET_MIN_RAYS = 32;
const float BUDGET_NEAR = 8.0;   // blocks; a lamp nearer than this gains no more rays
const float BUDGET_HIDDEN = 0.1;
const int LAMP_BIN = 16;
const int LAMP_BINS = VOXEL_SIZE / LAMP_BIN;
const int LAMP_BIN_CELLS = LAMP_BINS * LAMP_BINS * LAMP_BINS;
const int LAMP_BIN_MAX = LAMP_BIN_SLOTS;

layout(std430, binding = 1) buffer LightList {
    uint count[2];
    uint pad[2];
    uint rayStart[LIGHTS_MAX + 4];   // first ray of each lamp, [count] one past the last
    uint binCount[LAMP_BIN_CELLS];
    uint bins[LAMP_BIN_CELLS * LAMP_BIN_MAX];   // lamp indices per bin
    float budgetWeight[2 * LIGHTS_MAX];         // share of the bounce budget, per set
    uint guideSlot[2 * LIGHTS_MAX];             // tree of each lamp, see lib/guide.glsl
    uvec4 lights[];
} lightList;

int lightSet(int frame) { return frame & 1; }

// Lamp position in grid index space, see lampClusterOffset for a cluster
vec3 lampPosition(uvec4 L) {
    return vec3(L.xyz) + (lampClustered(L.w) ? lampClusterOffset(L.w) : voxelLampOffset(L.w));
}

uint lightCount(int set) {
    return min(lightList.count[set], uint(LIGHTS_MAX));
}

void lightsClear(int set) { lightList.count[set] = 0u; }

// Share of a lamp in the ray budget: its strength over the squared distance
// to the camera, which is where the bounce is looked at. The floor keeps a
// lamp beside the camera from starving the rest.
float lampBudgetWeight(uvec4 L, vec3 camGrid) {
    vec3 d = lampPosition(L) - camGrid;
    return lampStrength(L.w) / (dot(d, d) + BUDGET_NEAR * BUDGET_NEAR);
}

// vis is 1 for a lamp in the open and BUDGET_HIDDEN for one walled off
// from the camera, see lampCameraVisibility in lib/grid_step.glsl
void lightsAdd(int set, ivec3 idx, uint v, float vis, vec3 camGrid) {
    uint slot = atomicAdd(lightList.count[set], 1u);
    if (slot < uint(LIGHTS_MAX)) {
        uvec4 L = uvec4(uvec3(idx), v);
        lightList.lights[set * LIGHTS_MAX + int(slot)] = L;
        lightList.budgetWeight[set * LIGHTS_MAX + int(slot)] = lampBudgetWeight(L, camGrid) * vis;
    }
}

// Splits total rays between the lamps of a set: BUDGET_MIN_RAYS each, the
// rest by the stored weights, no lamp above BOUNCE_MAX_RAYS. The shares
// round down, so the sum never exceeds total; rays a cap leaves unspent
// stay unspent, the threads past the last lamp exit. Serial over the
// list; meant for a single thread once the list is complete.
void lightsBudget(int set, int total) {
    uint n = lightCount(set);
    float wsum = 0.0;
    for (uint i = 0u; i < n; i++) wsum += lightList.budgetWeight[set * LIGHTS_MAX + int(i)];
    float spare = float(max(total - int(n) * BUDGET_MIN_RAYS, 0));
    uint start = 0u;
    for (uint i = 0u; i < n; i++) {
        lightList.rayStart[i] = start;
        float w = lightList.budgetWeight[set * LIGHTS_MAX + int(i)];
        start += min(uint(BUDGET_MIN_RAYS) + uint(spare * w / max(wsum, 1e-9)), uint(BOUNCE_MAX_RAYS));
    }
    lightList.rayStart[n] = start;
}

// Lamp that ray t of the budget belongs to, or -1 past the last one
int lightOfRay(int set, uint t) {
    uint n = lightCount(set);
    if (n == 0u || t >= lightList.rayStart[n]) return -1;
    uint lo = 0u;
    uint hi = n;
    while (hi - lo > 1u) {
        uint mid = (lo + hi) >> 1u;
        if (lightList.rayStart[mid] <= t) lo = mid; else hi = mid;
    }
    return int(lo);
}

int lampBinIndex(ivec3 b) { return (b.z * LAMP_BINS + b.y) * LAMP_BINS + b.x; }

// Bin of a point in grid index space
int lampBinOf(vec3 pg) {
    ivec3 b = clamp(ivec3(floor(pg / float(LAMP_BIN))), ivec3(0), ivec3(LAMP_BINS - 1));
    return lampBinIndex(b);
}

// Fills bin bi from the list of set: every lamp within LPV_RANGE of the
// bin's box is a candidate, the LAMP_BIN_MAX best by strength over squared
// box distance are kept in order. binCount holds the candidates, so a
// bin that dropped some can be told. One thread per bin.
void lampBinGather(int set, int bi) {
    ivec3 b = ivec3(bi % LAMP_BINS, (bi / LAMP_BINS) % LAMP_BINS, bi / (LAMP_BINS * LAMP_BINS));
    vec3 lo = vec3(b) * float(LAMP_BIN);
    vec3 hi = lo + float(LAMP_BIN);
    uint idxs[LAMP_BIN_MAX];
    float keys[LAMP_BIN_MAX];
    int kept = 0;
    uint total = 0u;
    uint n = lightCount(set);
    for (uint i = 0u; i < n; i++) {
        uvec4 L = lightList.lights[set * LIGHTS_MAX + int(i)];
        float d = boxDistance(lampPosition(L), lo, hi);
        if (d > LPV_RANGE) continue;
        total++;
        float w = lampStrength(L.w) / (d * d + 4.0);
        w *= 1.0 + float(voxelHash(L.x ^ voxelHash(L.y ^ voxelHash(L.z))) & 0xFFFu) * 1e-6;
        if (kept == LAMP_BIN_MAX && w <= keys[LAMP_BIN_MAX - 1]) continue;
        int j = kept < LAMP_BIN_MAX ? kept : LAMP_BIN_MAX - 1;
        while (j > 0 && keys[j - 1] < w) {
            keys[j] = keys[j - 1];
            idxs[j] = idxs[j - 1];
            j--;
        }
        keys[j] = w;
        idxs[j] = i;
        if (kept < LAMP_BIN_MAX) kept++;
    }
    for (int j = 0; j < kept; j++) lightList.bins[bi * LAMP_BIN_MAX + j] = idxs[j];
    lightList.binCount[bi] = total;
}

uint lampBinCount(int bi) { return min(lightList.binCount[bi], uint(LAMP_BIN_MAX)); }
bool lampBinOverflow(int bi) { return lightList.binCount[bi] > uint(LAMP_BIN_MAX); }
int lampBinLamp(int bi, uint k) { return int(lightList.bins[bi * LAMP_BIN_MAX + int(k)]); }

#endif
