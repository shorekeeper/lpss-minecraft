#ifndef BOUNCE_GLSL
#define BOUNCE_GLSL
#include "/lib/settings.glsl"
#include "/lib/voxel.glsl"

// Indirect block light as a photon estimate on the voxel grid. Each frame a
// fixed budget of rays is split between the lamps of the light list by
// strength and nearness to the camera, see lib/lights.glsl; a ray leaves
// its lamp along one point of a stratified set over the sphere, warped by
// the lamp's guiding tree, see lib/guide.glsl, takes the albedo of the
// first occluder it enters, bounces
// off it by a cosine-weighted direction and deposits the carried flux,
// weighted by the cosine of arrival, into the air voxels in front of the
// second occluder, spread over that face by the hit point. Russian roulette
// on the albedo there decides whether the ray bounces once more and
// deposits again. Deposits accumulate in three fixed-point counters that
// the grid steps fold into a persistent volume with a temporal weight.
// Stored values are irradiance in the same units the direct term uses,
// before LPV_EMISSION. The first leg of a ray also feeds the fog volume,
// see lib/fogvol.glsl.

// Rays that get a lamp; the dispatch is fixed at the largest value of the
// knob and the threads past this exit at once
const int BOUNCE_THREADS = BOUNCE_RAYS;
// One ray of a single lamp carries about 1e-4; this keeps it at tens of
// counts and still leaves room for 4096 units per channel
const float BOUNCE_FIXED = 1048576.0;

uint bounceHash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}
float bounceRand(uint s) { return float(bounceHash(s) & 0xFFFFFFu) / 16777216.0; }

vec3 bounceDecode(uvec3 q) { return vec3(q) / BOUNCE_FIXED; }

// Point ri of a Fibonacci set of n points in the unit square, shifted
// toroidally by seed so the set is stratified within a frame and never the
// same across frames. Mapped to the sphere by the equal-area map of
// lib/guide.glsl, after the lamp's tree has warped it.
vec2 fibonacciSquare(uint ri, uint n, uint seed) {
    float u0 = bounceRand(seed);
    float u1 = bounceRand(seed + 1u);
    return vec2(fract((float(ri) + 0.5) / float(n) + u0), fract(float(ri) * 0.61803398875 + u1));
}

vec3 cosineDir(vec3 n, float u1, float u2) {
    vec3 t1 = normalize(cross(n, abs(n.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
    vec3 t2 = cross(n, t1);
    float r = sqrt(u1);
    float ph = 6.28318530718 * u2;
    return t1 * (r * cos(ph)) + t2 * (r * sin(ph)) + n * sqrt(max(0.0, 1.0 - u1));
}

#ifdef BOUNCE_MARCH
#define TERRAIN_HEAD_IMAGE
#include "/lib/terrain_tris.glsl"

// Defined by the including program: receives each air cell a fog ray
// crosses, the length crossed inside it and the distance from the lamp at
// the middle of that length
void fogDeposit(ivec3 cell, float len, float t);

// Walks the grid from p, in index space, along rd for at most maxDist.
// Returns true when an occluder is met, with its cell, the cell the ray
// was in before, the hit normal facing the ray and the distance travelled.
// A full cube is met at its cell face, a partial block at its triangles or
// full faces, a leaves cube by the leaf dither, see leavesPass. Entity
// boxes are passed through: they move, and the volume
// this feeds is blended over many frames. The cell of p is never tested.
// With fog set, every air cell crossed after the first is handed to
// fogDeposit.
bool marchVoxels(vec3 p, vec3 rd, float maxDist, bool fog, out ivec3 hit, out ivec3 before, out vec3 n, out float tHit) {
    ivec3 cell = ivec3(floor(p));
    ivec3 prev = cell;
    ivec3 stp = ivec3(sign(rd));
    vec3 inv = 1.0 / max(abs(rd), vec3(1e-6));
    vec3 tMax = abs(vec3(cell) + max(vec3(stp), vec3(0.0)) - p) * inv;
    float tIn = 0.0;
    for (int i = 0; i < 96; i++) {
        int ax = tMax.x < tMax.y ? (tMax.x < tMax.z ? 0 : 2) : (tMax.y < tMax.z ? 1 : 2);
        float t = tMax[ax];
        float tOut = min(t, maxDist);
        int exitFace = ax * 2 + (stp[ax] > 0 ? 0 : 1);
        if (i > 0) {
            uint v = imageLoad(voxelImg, cell).r;
            if (voxelPartial(v)) {
                vec3 tn;
                vec3 lo, hi;
                voxelSpan(v, lo, hi);
                float th = -1.0;
                if (raySegmentBox(p, rd, tIn - 1e-3, tOut + 1e-3, vec3(cell) + lo, vec3(cell) + hi)) {
                    th = traceTerrainCell(cell, p, rd, tIn - 1e-3, tOut + 1e-3, tn);
                }
                if (th < 0.0 && t < maxDist && voxelFaceFull(v, exitFace)) {
                    th = t;
                    tn = vec3(0.0);
                    tn[ax] = -float(stp[ax]);
                }
                if (th >= 0.0) {
                    if (fog) fogDeposit(cell, max(th - tIn, 0.0), 0.5 * (th + tIn));
                    hit = cell;
                    before = prev;
                    n = tn;
                    tHit = th;
                    return true;
                }
            }
            if (fog) fogDeposit(cell, tOut - tIn, 0.5 * (tOut + tIn));
        }
        if (t >= maxDist) return false;
        ivec3 next = cell;
        next[ax] += stp[ax];
        if (!voxelInside(next)) return false;
        uint nv = imageLoad(voxelImg, next).r;
        bool blocked = voxelFull(nv) || (voxelPartial(nv) && voxelFaceFull(nv, exitFace ^ 1));
        if (blocked && voxelLeaves(nv) && leavesPass(p + rd * t + vec3(voxelOrigin(cameraPosition)), exitFace ^ 1)) blocked = false;
        if (blocked) {
            hit = next;
            before = cell;
            n = vec3(0.0);
            n[ax] = -float(stp[ax]);
            tHit = t;
            return true;
        }
        prev = cell;
        cell = next;
        tIn = t;
        tMax[ax] += inv[ax];
    }
    return false;
}
#endif

#endif

