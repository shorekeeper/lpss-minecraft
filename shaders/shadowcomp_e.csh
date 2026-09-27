#version 430
#include "/lib/settings.glsl"
#include "/lib/voxel.glsl"
#include "/lib/near.glsl"
#include "/lib/skyvol.glsl"

// Sky visibility on the grid, see lib/skyvol.glsl. Every air cell within
// two steps of an occluder, which is every cell the volume taps of
// lib/volume.glsl can read, shoots cosine-weighted rays upwards from
// random points inside it through the voxel grid; a ray that leaves the
// grid or travels SKY_RANGE without meeting terrain sees the sky. Entity
// boxes are passed through, leaves by their dither, partial blocks by
// their triangles, those of the cell itself included.
//
// The moments are a running mean over the rays the cell has shot: the
// blocks are static and a change nearby raises this frame's reset flag,
// so the mean needs no floor on the weight of a new ray and stands still
// once settled. A cell holding fewer than SKY_SETTLE rays shoots SKY_BURST
// per frame, so a fresh or reset cell settles within a few frames instead
// of flickering for seconds. Cells no tap reads hold an open sky; filled
// cells hold nothing.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
const ivec3 workGroups = ivec3(16, 16, 16);

layout(r32ui) uniform readonly uimage3D voxelImg;
layout(r8ui)  uniform readonly uimage3D resetImgA;
layout(r8ui)  uniform readonly uimage3D resetImgB;

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform int frameCounter;

#define BOUNCE_MARCH
#include "/lib/bounce.glsl"

const float SKY_RANGE = 64.0;
// Moments of an unobstructed sky: the mean of a cosine-weighted
// hemisphere points 2/3 up
const vec4 SKY_OPEN = vec4(0.0, 0.66667, 0.0, 1.0);
const ivec3 SKY_FACE[6] = ivec3[6](
    ivec3( 1, 0, 0), ivec3(-1, 0, 0),
    ivec3( 0, 1, 0), ivec3( 0,-1, 0),
    ivec3( 0, 0, 1), ivec3( 0, 0,-1));

// The march offers every air cell it crosses to the fog; nothing to do here
void fogDeposit(ivec3 cell, float len, float t) {}

uint rngSeed;
uint rngCount = 0u;
float rnd() { return bounceRand(rngSeed + rngCount++); }

// Whether a stored value can have come from this program: the mean no
// longer than the share and pointing up. The buffer starts as whatever
// memory held.
bool skySane(vec4 m) {
    if (m.y < -0.01 || m.y > m.a + 0.02) return false;
    return length(m.xyz) <= m.a + 0.02;
}

void main() {
#if SKIP_COMPUTE || !SKY_GRID_ENABLED || SKIP_SKY
    return;
#endif
    ivec3 idx = ivec3(gl_GlobalInvocationID);
    if (!voxelInside(idx)) return;
    bool even = (frameCounter & 1) == 0;
    int set = skySet(frameCounter);

    uvec2 nc = nearCell(idx);
    uint v = nc.y;
    if (voxelFillsCentre(v)) { skyStore(set, idx, vec4(0.0), 0u, 0u); return; }

    bool traced = nearSelfOccluder(nc.x) || nearAnyOccluder(nc.x);
    for (int k = 0; k < 6 && !traced; k++) {
        ivec3 n = idx + SKY_FACE[k];
        if (voxelInside(n) && nearAnyOccluder(nearMask(n))) traced = true;
    }
    if (!traced) { skyStore(set, idx, SKY_OPEN, 0u, 0u); return; }

    ivec3 s = idx + ivec3(floor(cameraPosition)) - ivec3(floor(previousCameraPosition));
    vec4 prev = SKY_OPEN;
    float n = 0.0;
    uint resets = 0u;
    if (voxelInside(s)) {
        uint pn = skyCount(1 - set, s);
        prev = skyMoments(1 - set, s);
        if (pn > uint(SKY_HISTORY) || !skySane(prev)) prev = SKY_OPEN;
        else { n = float(pn); resets = min(skyResets(1 - set, s), 1000u); }
    }
    if ((even ? imageLoad(resetImgA, idx).r : imageLoad(resetImgB, idx).r) != 0u) { n = 0.0; resets++; }
    int rays = n < float(SKY_SETTLE) ? SKY_BURST : SKY_RAYS;

    // The stream is keyed by the world position, so a cell keeps its
    // sequence while the camera moves
    ivec3 wp = idx + voxelOrigin(cameraPosition);
    rngSeed = bounceHash(uint(wp.x) * 73856093u ^ uint(wp.y) * 19349663u ^ uint(wp.z) * 83492791u)
            ^ (uint(frameCounter) * 2654435761u);

    vec4 sum = vec4(0.0);
    for (int r = 0; r < rays; r++) {
        vec3 p = vec3(idx) + 0.1 + 0.8 * vec3(rnd(), rnd(), rnd());
        vec3 rd = cosineDir(vec3(0.0, 1.0, 0.0), rnd(), rnd());
        bool blocked = false;
        if (voxelPartial(v)) {
            // The march never tests the cell it starts in
            vec3 tn;
            blocked = traceTerrainCell(idx, p, rd, 0.0, 2.0, tn) > 0.0;
        }
        if (!blocked) {
            ivec3 hit, before; vec3 tn; float th;
            blocked = marchVoxels(p, rd, SKY_RANGE, false, hit, before, tn, th);
        }
        if (!blocked) sum += vec4(rd, 1.0);
    }

    float total = n + float(rays);
    vec4 o = (prev * n + sum) / total;
    skyStore(set, idx, o, uint(min(total, float(SKY_HISTORY))), resets);
}