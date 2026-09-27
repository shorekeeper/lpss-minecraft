#ifndef VOXEL_GLSL
#define VOXEL_GLSL
#include "/lib/settings.glsl"

// A 128^3 grid of blocks anchored to floor(cameraPosition). Both the shadow
// pass and the deferred pass see the same cameraPosition within a frame, so
// the origin agrees without any extra uniform. No uniforms are declared here:
// this file is shared by vertex, geometry, compute and fragment stages.

const int VOXEL_SIZE = 128;
const int VOXEL_HALF = 64;

#if DEBUG_VIEW == 14
// Work of the traces of one pixel: cells of any grid visited and
// triangles tested
int traceCost = 0;
#endif

ivec3 voxelOrigin(vec3 cam) { return ivec3(floor(cam)) - VOXEL_HALF; }

bool voxelInside(ivec3 i) {
    return all(greaterThanEqual(i, ivec3(0))) && all(lessThan(i, ivec3(VOXEL_SIZE)));
}

// bit 0: solid by id   bits 1-4: emission 0..15   bits 5-6: colour class 0..3
// bit 7: partial, a triangle with a vertex off the block boundary was seen
// bits 8-13: full faces in +X -X +Y -Y +Z -Z order, a triangle with all
// three vertices on block corners lying in that face was seen
// bits 14-25: quarters of the block the mesh's vertices occupy, four per
// axis in x y z order; for a partial block this bounds its triangles, for
// an emitter it places the lamp at the centre of the span
// bit 26: entity box, a triangle of a mob, block entity or item touched
// the cell
// bit 27: leaves, a cube whose faces the traces pass by a fixed dither
// with probability LEAVES_TRANSMIT, see leavesPass
// Triangles OR their bits in, so the value accumulates over the block's mesh.
uint packVoxel(bool solid, int emission, int colorClass) {
    return (solid ? 1u : 0u)
         | (uint(clamp(emission, 0, 15)) << 1)
         | (uint(colorClass & 3) << 5);
}
const uint VOXEL_PARTIAL = 0x80u;
const int VOXEL_FACE_SHIFT = 8;
const uint VOXEL_ALL_FACES = 63u << 8;
const int VOXEL_SPAN_SHIFT = 14;
const uint VOXEL_ENTITY = 1u << 26;
const uint VOXEL_LEAVES = 1u << 27;

// Quarter bits of one vertex at block local position l
uint voxelSpanBits(vec3 l) {
    ivec3 q = clamp(ivec3(floor(l * 4.0)), ivec3(0), ivec3(3));
    return ((1u << uint(q.x)) | (1u << uint(4 + q.y)) | (1u << uint(8 + q.z))) << uint(VOXEL_SPAN_SHIFT);
}

// Bounds of the mesh in block units, the whole block on an axis with no bits
void voxelSpan(uint v, out vec3 lo, out vec3 hi) {
    lo = vec3(0.0);
    hi = vec3(1.0);
    for (int a = 0; a < 3; a++) {
        uint q = (v >> uint(VOXEL_SPAN_SHIFT + a * 4)) & 15u;
        if (q == 0u) continue;
        int l = (q & 1u) != 0u ? 0 : ((q & 2u) != 0u ? 1 : ((q & 4u) != 0u ? 2 : 3));
        int h = (q & 8u) != 0u ? 3 : ((q & 4u) != 0u ? 2 : ((q & 2u) != 0u ? 1 : 0));
        lo[a] = 0.25 * float(l);
        hi[a] = 0.25 * float(h + 1);
    }
}

// Lamp position inside its block: the centre of the span
vec3 voxelLampOffset(uint v) {
    vec3 lo, hi;
    voxelSpan(v, lo, hi);
    return 0.5 * (lo + hi);
}

// A block the mesh never touched but which must be a full opaque cube, see
// voxelEnclosedBy
const uint VOXEL_ENCLOSED = 1u | VOXEL_ALL_FACES;

bool voxelSolid(uint v)      { return (v & 1u) != 0u; }
int  voxelEmission(uint v)   { return int((v >> 1) & 15u); }
int  voxelColorClass(uint v) { return int((v >> 5) & 3u); }
bool voxelPartial(uint v)    { return (v & VOXEL_PARTIAL) != 0u; }
bool voxelFaceFull(uint v, int k) { return ((v >> uint(VOXEL_FACE_SHIFT + k)) & 1u) != 0u; }

bool voxelEntity(uint v) { return (v & VOXEL_ENTITY) != 0u; }
bool voxelLeaves(uint v) { return (v & VOXEL_LEAVES) != 0u; }

// Whether the mesh touched the block: only its vertices set span bits, an
// inferred voxel has none
bool voxelFromMesh(uint v) { return ((v >> uint(VOXEL_SPAN_SHIFT)) & 0xFFFu) != 0u; }

uint voxelHash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

// Whether a ray entering a leaves cube by face k at world point p gets
// through. The leaf coverage is a fixed dither on the face at 1/16 block,
// so the shadow of a crown is dappled and stays put in the world.
bool leavesPass(vec3 p, int k) {
    ivec3 q = ivec3(floor(p * 16.0));
    int ax = k >> 1;
    q[ax] = int(round(p[ax])) * 16;
    uint h = voxelHash(uint(q.x) * 73856093u ^ uint(q.y) * 19349663u ^ uint(q.z) * 83492791u);
    return float(h & 0xFFFFu) / 65536.0 < LEAVES_TRANSMIT;
}

// A solid block whose mesh showed a full face and no partial triangle is a
// full cube. Ground seen from above alone counts.
bool voxelFull(uint v) {
    return voxelSolid(v) && !voxelPartial(v) && (v & VOXEL_ALL_FACES) != 0u;
}

// A cell the traces stop at as a whole: a full cube of terrain or the box
// of an entity
bool voxelCube(uint v) { return voxelFull(v) || voxelEntity(v); }

// What the traces stop at: a cube as its whole cell, a partial block by its
// triangles, see lib/terrain_tris.glsl
bool voxelOccluder(uint v) {
    return voxelCube(v) || (voxelSolid(v) && voxelPartial(v));
}

// Cells the light volumes treat as filled. A partial block leaves air in
// its cell and is sampled and deposited into like air; so does an entity,
// which moves and must not drop the taps of the floor under it.
bool voxelFillsCentre(uint v) { return voxelFull(v); }

// The mesh culls a face only against a full opaque cube. So a voxel the mesh
// never touched, next to a full cube whose face towards it holds no
// triangle, is such a cube itself: buried ground, the block under a wall.
// k is the face of the neighbour that points at the voxel.
bool voxelEnclosedBy(uint neighbour, int k) {
    return voxelFull(neighbour) && !voxelFaceFull(neighbour, k);
}

// mid is at_midBlock.xyz in 1/64 block units, from the vertex to the block
// centre. A vine sits 1/16 off its wall and must not read as a face.
bool voxelOnCorner(vec3 mid) {
    return all(greaterThanEqual(abs(mid), vec3(31.0)));
}

// Whether a triangle with normal n lies in an axis-aligned plane. Only such
// a triangle can be a full face; the crossed quads of plants always go to
// the triangle list.
bool voxelAxisAligned(vec3 n) {
    vec3 an = abs(n);
    return max(an.x, max(an.y, an.z)) >= 0.995 * length(n);
}

// Full face bit of a triangle whose vertices, in block local coordinates,
// all sit on block corners: the face is the plane the three share
uint voxelFaceBitOf(vec3 l0, vec3 l1, vec3 l2) {
    vec3 e = abs(l1 - l0) + abs(l2 - l0);
    int ax = (e.x <= e.y && e.x <= e.z) ? 0 : (e.y <= e.z ? 1 : 2);
    int face = ax * 2 + (l0[ax] > 0.5 ? 0 : 1);
    return 1u << uint(VOXEL_FACE_SHIFT + face);
}

// id is the material id already offset by 10000. solid means "occludes by
// its mesh". Emission comes from the id alone: on this fork at_midBlock.w
// carries the block light received by the block, not what it emits, so a
// lamp has to be mapped in block.properties.
void classifyVoxel(int id, out bool solid, out int emission, out int colorClass, out bool leaves) {
    solid = true; emission = 0; colorClass = 0;
    leaves = id == 10;
    if (id == 1)      { solid = false; emission = 14; colorClass = 1; }
    else if (id == 11) { solid = false; emission = 15; colorClass = 0; }
    else if (id == 2 || id == 8 || id == 9) { solid = false; }
    else if (id == 6) { solid = false; emission = 15; colorClass = 2; }
    else if (id == 7) { solid = false; emission = 7;  colorClass = 3; }
}

vec3 emissionColor(int c) {
    if (c == 1) return vec3(1.00, 0.58, 0.24); // sodium vapour
    if (c == 2) return vec3(1.00, 0.42, 0.10); // fire, lava
    if (c == 3) return vec3(1.00, 0.18, 0.06); // redstone
    return vec3(0.82, 0.90, 1.00);             // floodlight: cold white
}


float boxDistance(vec3 p, vec3 bmin, vec3 bmax) {
    return length(max(max(bmin - p, p - bmax), vec3(0.0)));
}

// Whether a + t * rd, t in t0 .. t1, meets the box
bool raySegmentBox(vec3 a, vec3 rd, float t0, float t1, vec3 bmin, vec3 bmax) {
    vec3 rds = rd + vec3(lessThan(abs(rd), vec3(1e-6))) * 1e-6;
    vec3 inv = 1.0 / rds;
    vec3 ta = (bmin - a) * inv;
    vec3 tb = (bmax - a) * inv;
    vec3 tn = min(ta, tb);
    vec3 tf = max(ta, tb);
    float tEnter = max(max(max(tn.x, tn.y), tn.z), t0);
    float tExit = min(min(min(tf.x, tf.y), tf.z), t1);
    return tEnter <= tExit;
}

// Moller-Trumbore, both windings. Returns the ray parameter, or -1 on a
// miss; bary holds the weights of b and c at the hit.
float rayTriangle(vec3 ro, vec3 rd, vec3 a, vec3 b, vec3 c, out vec2 bary) {
    bary = vec2(0.0);
    vec3 e1 = b - a;
    vec3 e2 = c - a;
    vec3 p = cross(rd, e2);
    float det = dot(e1, p);
    if (abs(det) < 1e-8) return -1.0;
    float inv = 1.0 / det;
    vec3 s = ro - a;
    float u = dot(s, p) * inv;
    if (u < 0.0 || u > 1.0) return -1.0;
    vec3 q = cross(s, e1);
    float v = dot(rd, q) * inv;
    if (v < 0.0 || u + v > 1.0) return -1.0;
    bary = vec2(u, v);
    return dot(e2, q) * inv;
}

float rayTriangle(vec3 ro, vec3 rd, vec3 a, vec3 b, vec3 c) {
    vec2 bary;
    return rayTriangle(ro, rd, a, b, c, bary);
}

#endif

