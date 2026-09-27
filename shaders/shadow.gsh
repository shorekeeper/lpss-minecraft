#version 430 compatibility
#include "/lib/settings.glsl"
#include "/lib/voxel.glsl"
#include "/lib/entity_tris.glsl"
#define TERRAIN_HEAD_IMAGE
#define TERRAIN_WRITE
#include "/lib/terrain_tris.glsl"

// Terrain voxelization, second half, and entity handling. A terrain
// triangle belongs to one block. Three vertices on block corners in an
// axis plane make a full face of that block; otherwise the block is
// partial and the triangle goes into its cell's list for the traces, with
// its place on its sprite and the sprite's alpha mask, see
// lib/terrain_tris.glsl.
//
// Everything without at_midBlock is an entity or a block entity. An
// unbound attribute reads as one constant for the whole draw, so three
// identical at_midBlock values are an entity as well. Triangles within
// PLAYER_REACH of the camera belong to the local player and are appended
// to this frame's set, camera-relative, growing the set's bounding box, so
// the deferred pass can trace sharp shadows against the posed mesh. The
// rest mark cells as entity boxes in the voxel grid: mobs, chests and
// carts shadow as blocks. Triangles smaller than ENTITY_MIN_SIZE are
// particles, dropped items and arrows and are skipped.

layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;

uniform int frameCounter;
uniform vec3 cameraPosition;

layout(r32ui) uniform uimage3D voxelImg;
layout(rgba8) uniform writeonly image3D voxelColorImg;

in vec3 gWorld[];
in vec3 gMid[];
in vec2 gUV[];
in vec3 gAlbedo[];
flat in vec2 gMidUV[];
flat in int gTerrain[];
flat in uint gVoxel[];
flat in ivec3 gIdx[];
#if DEBUG_VIEW == 24
flat in vec3 gNormal[];
#endif

const float PLAYER_REACH = 2.5;
const float ENTITY_MIN_SIZE = 0.3;
const float ENTITY_BOX_SIZE = 1.5;     // larger triangles mark their whole bounding box
const int ENTITY_BOX_SPAN = 3;
const vec3 ENTITY_ALBEDO = vec3(0.35);

void capturePlayer(vec3 a, vec3 b, vec3 c) {
    int set = entityTriSet(frameCounter);
    uint slot = atomicAdd(entityTris.count[set], 1u);
    if (slot < uint(ENTITY_TRIS_MAX)) {
        uint base = entityTriBase(set, slot);
        entityTris.verts[base]      = vec4(a, 0.0);
        entityTris.verts[base + 1u] = vec4(b, 0.0);
        entityTris.verts[base + 2u] = vec4(c, 0.0);
    }
    entityTrisGrow(set, a, b, c);
}

void boxEntity(vec3 a, vec3 b, vec3 c) {
    vec3 lo = min(a, min(b, c));
    vec3 hi = max(a, max(b, c));
    float ext = max(hi.x - lo.x, max(hi.y - lo.y, hi.z - lo.z));
    if (ext < ENTITY_MIN_SIZE) return;
    vec3 shift = cameraPosition - vec3(voxelOrigin(cameraPosition));
    ivec3 c0, c1;
    if (ext < ENTITY_BOX_SIZE) {
        // A body panel marks the cell of its centroid, so a low cart
        // straddling a boundary does not become a wall of three
        c0 = ivec3(floor((a + b + c) / 3.0 + shift));
        c1 = c0;
    } else {
        c0 = ivec3(floor(lo + shift));
        c1 = min(ivec3(floor(hi + shift)), c0 + (ENTITY_BOX_SPAN - 1));
    }
    for (int z = c0.z; z <= c1.z; z++)
    for (int y = c0.y; y <= c1.y; y++)
    for (int x = c0.x; x <= c1.x; x++) {
        ivec3 cell = ivec3(x, y, z);
        if (!voxelInside(cell)) continue;
        imageAtomicOr(voxelImg, cell, VOXEL_ENTITY);
        imageStore(voxelColorImg, cell, vec4(ENTITY_ALBEDO, 1.0));
    }
}

void handleEntity() {
    vec3 a = gWorld[0];
    vec3 b = gWorld[1];
    vec3 c = gWorld[2];
    vec3 n = cross(b - a, c - a);
    if (dot(n, n) <= 1e-10) return;
    if (length(a + b + c) < 3.0 * PLAYER_REACH) capturePlayer(a, b, c); else boxEntity(a, b, c);
}

// Position of each vertex on its sprite, from the offsets of the atlas
// coordinates to the sprite centre; a quad of a whole sprite puts the
// corners at plus and minus its half extent
void addPartial(int set, ivec3 idx, vec3 l0, vec3 l1, vec3 l2) {
    if (terrainDuplicate(set, idx, l0, l1, l2)) return;
    vec2 mid = gMidUV[0];
    vec2 h = max(max(abs(gUV[0] - mid), abs(gUV[1] - mid)), abs(gUV[2] - mid));
    h = max(h, vec2(1e-6));
    vec2 la = (gUV[0] - mid) / h * 0.5 + 0.5;
    vec2 lb = (gUV[1] - mid) / h * 0.5 + 0.5;
    vec2 ld = (gUV[2] - mid) / h * 0.5 + 0.5;
    terrainTrisAdd(set, idx, l0, l1, l2, la, lb, ld, terrainMaskSlot(set, mid, h));
}

void voxelizeTerrain() {
    uint v = gVoxel[0];
    ivec3 idx = gIdx[0];
    if (v == 0u || !voxelInside(idx)) return;
#if DEBUG_VIEW == 16
    imageStore(voxelColorImg, idx, vec4(gAlbedo[0], 1.0));
    return;
#endif
    vec3 l0 = 0.5 - gMid[0] / 64.0;
    vec3 l1 = 0.5 - gMid[1] / 64.0;
    vec3 l2 = 0.5 - gMid[2] / 64.0;
    if (voxelSolid(v)) {
        vec3 n = cross(l1 - l0, l2 - l0);
        if (dot(n, n) < 1e-10) return;
#if DEBUG_VIEW == 24
        // Bits 30 and 31 of the voxel are free; the vertex order agrees
        // with the vertex normal or it does not
        if (voxelAxisAligned(n)) {
            imageAtomicOr(voxelImg, idx, dot(n, gNormal[0]) > 0.0 ? (1u << 30) : (1u << 31));
        }
#endif
        bool face = voxelAxisAligned(n) && voxelOnCorner(gMid[0]) && voxelOnCorner(gMid[1]) && voxelOnCorner(gMid[2]);
        if (face) {
            v |= voxelFaceBitOf(l0, l1, l2);
        } else {
            v |= VOXEL_PARTIAL;
            addPartial(terrainTriSet(frameCounter), idx, l0, l1, l2);
        }
        imageStore(voxelColorImg, idx, vec4(gAlbedo[0], 1.0));
    }
    v |= voxelSpanBits(l0) | voxelSpanBits(l1) | voxelSpanBits(l2);
    imageAtomicOr(voxelImg, idx, v);
}

void main() {
#if !SKIP_SHADOW
    bool sameMid = all(equal(gMid[0], gMid[1])) && all(equal(gMid[1], gMid[2]));
    if (gTerrain[0] == 1 && !sameMid) voxelizeTerrain(); else handleEntity();
#endif
    for (int i = 0; i < 3; i++) {
        gl_Position = gl_in[i].gl_Position;
        EmitVertex();
    }
    EndPrimitive();
}
