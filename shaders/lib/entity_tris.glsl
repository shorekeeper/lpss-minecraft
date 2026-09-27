#ifndef ENTITY_TRIS_GLSL
#define ENTITY_TRIS_GLSL
#include "/lib/voxel.glsl"

// Triangles of everything the shadow pass draws without at_midBlock, which
// on this fork is the player with whatever it wears and holds. Captured each
// frame by shadow.gsh into one of two sets alternating by frame parity: the
// shadow pass fills set (frameCounter & 1), the deferred pass reads it the
// same frame, and the first grid step clears the other set for the next
// frame. Positions are relative to the cameraPosition of the capturing frame.
//
// Each set carries the bounding box of its triangles. The second grid step
// bins this frame's triangles into an ENTITY_GRID^3 grid over that box as
// linked lists: one head per cell, one node per (cell, triangle) pair. The
// node pool holds the worst case, so a cell never drops a triangle and the
// bins hold the same triangles every frame.

const int ENTITY_TRIS_MAX = 4096;
const int ENTITY_GRID = 8;
const int ENTITY_CELLS = ENTITY_GRID * ENTITY_GRID * ENTITY_GRID;
const int ENTITY_SPAN = ENTITY_GRID;                        // cells per axis one triangle may touch
const int ENTITY_NODES = ENTITY_TRIS_MAX * ENTITY_SPAN * ENTITY_SPAN * ENTITY_SPAN;

layout(std430, binding = 0) buffer EntityTris {
    uint count[2];
    uint nodeCount;               // nodes used by this frame's bins
    uint pad;
    int bbox[16];                 // [set * 8 + k]; k 0-2 min xyz, 3-5 max xyz, ordered float bits
    uint cellHead[ENTITY_CELLS];  // node index + 1, 0 = empty
    uint nodes[ENTITY_NODES];     // bits 0-11 triangle, bits 12-31 next node index + 1
    vec4 verts[];
} entityTris;

int entityTriSet(int frame) { return frame & 1; }

uint entityTriCount(int set) {
    return min(entityTris.count[set], uint(ENTITY_TRIS_MAX));
}

uint entityTriBase(int set, uint tri) {
    return (uint(set) * uint(ENTITY_TRIS_MAX) + tri) * 3u;
}

// Float bits remapped so that integer ordering matches float ordering; the
// mapping is its own inverse
int orderedFloatBits(float f) { int i = floatBitsToInt(f); return i < 0 ? i ^ 0x7FFFFFFF : i; }
float orderedBitsToFloat(int i) { return intBitsToFloat(i < 0 ? i ^ 0x7FFFFFFF : i); }

void entityTrisClear(int set) {
    entityTris.count[set] = 0u;
    for (int k = 0; k < 6; k++) {
        entityTris.bbox[set * 8 + k] = k < 3 ? orderedFloatBits(1e30) : orderedFloatBits(-1e30);
    }
}

// Called once per frame by the first grid step, after the shadow pass has
// filled this frame's set: frees the other set and resets the node pool
void entityTrisFrameStart(int set) {
    entityTrisClear(1 - set);
    entityTris.nodeCount = 0u;
}

void entityBinsClear(int lin) {
    if (lin < ENTITY_CELLS) entityTris.cellHead[lin] = 0u;
}

void entityTrisGrow(int set, vec3 a, vec3 b, vec3 c) {
    vec3 lo = min(a, min(b, c));
    vec3 hi = max(a, max(b, c));
    for (int k = 0; k < 3; k++) {
        atomicMin(entityTris.bbox[set * 8 + k], orderedFloatBits(lo[k]));
        atomicMax(entityTris.bbox[set * 8 + 3 + k], orderedFloatBits(hi[k]));
    }
}

// False when the set holds nothing
bool entityTrisBounds(int set, out vec3 lo, out vec3 hi) {
    for (int k = 0; k < 3; k++) {
        lo[k] = orderedBitsToFloat(entityTris.bbox[set * 8 + k]);
        hi[k] = orderedBitsToFloat(entityTris.bbox[set * 8 + 3 + k]);
    }
    return all(lessThanEqual(lo, hi));
}

// Grid origin and cell size over the set's bounding box
bool entityGridFrame(int set, out vec3 lo, out vec3 cs) {
    vec3 hi;
    if (!entityTrisBounds(set, lo, hi)) return false;
    cs = max(hi - lo, vec3(1e-3)) / float(ENTITY_GRID);
    return true;
}

int entityCellIndex(ivec3 c) { return (c.z * ENTITY_GRID + c.y) * ENTITY_GRID + c.x; }

// Links one triangle into every cell its bounding box touches; the pool is
// sized for a triangle touching every cell.
void entityTrisBin(int set, uint tri) {
    vec3 lo, cs;
    if (!entityGridFrame(set, lo, cs)) return;
    uint b = entityTriBase(set, tri);
    vec3 a = entityTris.verts[b].xyz;
    vec3 bb = entityTris.verts[b + 1u].xyz;
    vec3 c = entityTris.verts[b + 2u].xyz;
    ivec3 c0 = clamp(ivec3(floor((min(a, min(bb, c)) - lo) / cs)), ivec3(0), ivec3(ENTITY_GRID - 1));
    ivec3 c1 = clamp(ivec3(floor((max(a, max(bb, c)) - lo) / cs)), ivec3(0), ivec3(ENTITY_GRID - 1));
    for (int z = c0.z; z <= c1.z; z++)
    for (int y = c0.y; y <= c1.y; y++)
    for (int x = c0.x; x <= c1.x; x++) {
        uint node = atomicAdd(entityTris.nodeCount, 1u);
        if (node >= uint(ENTITY_NODES)) return;
        int ci = entityCellIndex(ivec3(x, y, z));
        uint prev = atomicExchange(entityTris.cellHead[ci], node + 1u);
        entityTris.nodes[node] = tri | (prev << 12);
    }
}


// Nearest hit among the triangles linked into one cell, or -1
float traceEntityCell(int set, int ci, vec3 ro, vec3 rd, float tmin, float tmax) {
    float best = -1.0;
    uint n = entityTris.cellHead[ci];
    for (int guard = 0; guard < 1024 && n != 0u; guard++) {
#if DEBUG_VIEW == 14
        traceCost++;
#endif
        uint node = entityTris.nodes[n - 1u];
        uint b = entityTriBase(set, node & 0xFFFu);
        float t = rayTriangle(ro, rd,
            entityTris.verts[b].xyz, entityTris.verts[b + 1u].xyz, entityTris.verts[b + 2u].xyz);
        if (t > tmin && t < tmax) { tmax = t; best = t; }
        n = node >> 12;
    }
    return best;
}

// Walks the grid along ro + t * rd and returns the nearest hit inside the
// first cell that holds one, or -1. Exact for shadow rays, which only ask
// whether anything is in the way. lo and cs are the set's grid frame, see
// entityGridFrame, read once by the caller for all its rays.
float traceEntityTrisFrame(int set, vec3 lo, vec3 cs, vec3 ro, vec3 rd, float tmin, float tmax) {
    vec3 hi = lo + cs * float(ENTITY_GRID);

    vec3 rds = rd + vec3(lessThan(abs(rd), vec3(1e-6))) * 1e-6;
    vec3 inv = 1.0 / rds;
    vec3 ta = (lo - ro) * inv;
    vec3 tb = (hi - ro) * inv;
    vec3 tn = min(ta, tb);
    vec3 tf = max(ta, tb);
    float tEnter = max(max(max(tn.x, tn.y), tn.z), tmin);
    float tExit = min(min(min(tf.x, tf.y), tf.z), tmax);
    if (tEnter > tExit) return -1.0;

    vec3 p = (ro + rds * tEnter - lo) / cs;
    ivec3 cell = clamp(ivec3(floor(p)), ivec3(0), ivec3(ENTITY_GRID - 1));
    ivec3 stp = ivec3(sign(rds));
    vec3 dt = cs / abs(rds);
    vec3 tNext = tEnter + (vec3(cell) + max(vec3(stp), vec3(0.0)) - p) * cs / rds;

    for (int i = 0; i < 3 * ENTITY_GRID; i++) {
#if DEBUG_VIEW == 14
        traceCost++;
#endif
        float best = traceEntityCell(set, entityCellIndex(cell), ro, rd, tmin, tmax);
        if (best > 0.0) return best;

        int ax = tNext.x < tNext.y ? (tNext.x < tNext.z ? 0 : 2) : (tNext.y < tNext.z ? 1 : 2);
        if (tNext[ax] > tExit) return -1.0;
        cell[ax] += stp[ax];
        if (cell[ax] < 0 || cell[ax] >= ENTITY_GRID) return -1.0;
        tNext[ax] += dt[ax];
    }
    return -1.0;
}

float traceEntityTris(int set, vec3 ro, vec3 rd, float tmin, float tmax) {
    vec3 lo, cs;
    if (!entityGridFrame(set, lo, cs)) return -1.0;
    return traceEntityTrisFrame(set, lo, cs, ro, rd, tmin, tmax);
}

bool entitySegmentBlocked(int set, vec3 ro, vec3 rd, float len) {
    return traceEntityTris(set, ro, rd, 0.02, len) > 0.0;
}

#endif

