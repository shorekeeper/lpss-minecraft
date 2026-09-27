#ifndef TERRAIN_TRIS_GLSL
#define TERRAIN_TRIS_GLSL
#include "/lib/voxel.glsl"

// Triangles of partial blocks, for the traces. shadow.gsh appends every
// terrain triangle that is not a full face of its block, in the block's
// local coordinates from at_midBlock, and links it into the head of its
// cell. The heads live in an image the loader clears each frame; the slots
// are counted per frame parity like the light list, and the first grid
// step resets the other frame's count. The local coordinates come from the
// vertex attribute and not from the relayed positions, which drift, so the
// triangles sit exactly in their cells. Plants offset by the game reach a
// quarter block outside theirs, so the coordinates run from -0.5.
//
// The traces are bound by dependent loads, and a linked list costs one
// load per link. The second grid step therefore compacts every cell's list
// into a contiguous run of ctris and replaces the head with the run's
// offset and count; a trace fetches a run four records at a time, so
// their latencies overlap. The list form only lives through the shadow
// pass.
//
// A triangle also carries where its vertices sit on the rectangle its
// texture coordinates span and the index of that rectangle's alpha mask:
// 16x16 bits read from the atlas once per rectangle per frame, through a
// hash table keyed by the sprite centre and the rectangle's half extent.
// The pane of iron bars and its edge strip are different rectangles of
// one sprite and get their own masks. A ray meeting a triangle looks the
// mask up at the hit, so grass, flowers and bars shadow by their texture.
// Two records of uvec4 per triangle; the second is read on a hit only.
//
// The game draws the crossed quads of a plant twice, once per winding, to
// show them from both sides. The ray test takes either winding, so the
// second copy is dropped through a hash set of the triangle's cell and
// sorted vertices; a copy that slips past a collision only costs its test.
//
// A program that reads the lists defines TERRAIN_HEAD_IMAGE or
// TERRAIN_HEAD_SAMPLER before including this file; the shadow pass also
// defines TERRAIN_WRITE.

const int TERRAIN_TRIS_MAX = 262144;
const int TERRAIN_MASKS_MAX = 1024;
const int TERRAIN_DEDUP = 32768;           // slots per set, two uints each

layout(std430, binding = 4) buffer TerrainTris {
    uint count[2];
    uint compactCount;                     // records placed in ctris this frame
    uint pad;
    uint maskKey[2 * TERRAIN_MASKS_MAX];   // sprite key per set, 0 = free
    uint mask[TERRAIN_MASKS_MAX * 8];      // 16 rows of 16 bits, two rows per uint
    uint dedup[2 * TERRAIN_DEDUP * 2];     // vertex hash, cell + 1; 0 = free
    uvec4 tris[TERRAIN_TRIS_MAX * 2];      // as linked by the shadow pass
    uvec4 ctris[];                         // compacted by cell
} terrainTris;

int terrainTriSet(int frame) { return frame & 1; }
void terrainTrisClear(int set) { terrainTris.count[set] = 0u; }

void terrainMasksClear(int set, int lin) {
    if (lin < TERRAIN_MASKS_MAX) terrainTris.maskKey[set * TERRAIN_MASKS_MAX + lin] = 0u;
}

void terrainDedupClear(int set, int lin) {
    if (lin < 2 * TERRAIN_DEDUP) terrainTris.dedup[set * 2 * TERRAIN_DEDUP + lin] = 0u;
}

uint terrainTriCount(int set) {
    return min(terrainTris.count[set], uint(TERRAIN_TRIS_MAX));
}

// Head word of a compacted cell: offset in ctris and record count
uint terrainRange(uint off, uint count) { return (off & 0x3FFFFu) | (min(count, 16383u) << 18); }

// Block local coordinates in 1/64 from -0.5, one byte per axis
uint terrainPack(vec3 p) {
    uvec3 q = uvec3(clamp((p + 0.5) * 64.0 + 0.5, 0.0, 255.0));
    return q.x | (q.y << 8) | (q.z << 16);
}

vec3 terrainUnpack(uint u) {
    return vec3(float(u & 0xFFu), float((u >> 8) & 0xFFu), float((u >> 16) & 0xFFu)) / 64.0 - 0.5;
}

// Nonzero key of a mask: the sprite centre and the half extent of the
// rectangle sampled around it, both in atlas coordinates
uint terrainMaskKey(vec2 mid, vec2 h) {
    uvec2 qm = uvec2(clamp(mid, 0.0, 1.0) * 65535.0 + 0.5);
    uvec2 qh = uvec2(clamp(h, 0.0, 1.0) * 65535.0 + 0.5);
    return voxelHash((qm.x | (qm.y << 16)) ^ voxelHash(qh.x | (qh.y << 16))) | 0x80000000u;
}

bool terrainMaskBit(uint slot, ivec2 t) {
    uint w = terrainTris.mask[int(slot) * 8 + (t.y >> 1)];
    return ((w >> uint((t.y & 1) * 16 + t.x)) & 1u) != 0u;
}

#ifdef TERRAIN_HEAD_IMAGE
layout(r32ui) uniform uimage3D terrainHeadImg;
uint terrainHead(ivec3 c) { return imageLoad(terrainHeadImg, c).r; }
#endif

#ifdef TERRAIN_WRITE
uniform sampler2D gtexture;

// Whether the same three vertices were already added to cell c this frame.
// The cell goes in through the second word, written and read atomically so
// the other invocation sees it; a read that comes too early keeps a copy,
// which is harmless.
bool terrainDuplicate(int set, ivec3 c, vec3 a, vec3 b, vec3 d) {
    uvec3 p = uvec3(terrainPack(a), terrainPack(b), terrainPack(d));
    uint lo = min(p.x, min(p.y, p.z));
    uint hi = max(p.x, max(p.y, p.z));
    uint mid = p.x ^ p.y ^ p.z ^ lo ^ hi;
    uint k1 = voxelHash(lo ^ voxelHash(mid ^ voxelHash(hi))) | 1u;
    uint k2 = uint((c.z * VOXEL_SIZE + c.y) * VOXEL_SIZE + c.x) + 1u;
    uint s = k1 & uint(TERRAIN_DEDUP - 1);
    for (int probe = 0; probe < 4; probe++) {
        int i = (set * TERRAIN_DEDUP + int(s)) * 2;
        uint prev = atomicCompSwap(terrainTris.dedup[i], 0u, k1);
        if (prev == 0u) { atomicExchange(terrainTris.dedup[i + 1], k2); return false; }
        if (prev == k1 && atomicOr(terrainTris.dedup[i + 1], 0u) == k2) return true;
        s = (s + 1u) & uint(TERRAIN_DEDUP - 1);
    }
    return false;
}

// Slot of the mask for the rectangle centred at mid with half extent h, or
// -1 when the table is full. The thread that claims a free slot reads the
// alpha at the centres of a 16x16 grid over the rectangle.
int terrainMaskSlot(int set, vec2 mid, vec2 h) {
    uint key = terrainMaskKey(mid, h);
    uint s = voxelHash(key) & uint(TERRAIN_MASKS_MAX - 1);
    for (int probe = 0; probe < 8; probe++) {
        int i = set * TERRAIN_MASKS_MAX + int(s);
        // Every blade of grass in the frame shares one key; a plain read
        // finds the slot already claimed, and the atomic runs only while it
        // is free
        uint prev = terrainTris.maskKey[i];
        if (prev == key) return int(s);
        if (prev == 0u) prev = atomicCompSwap(terrainTris.maskKey[i], 0u, key);
        if (prev == 0u) {
            uint bits[8];
            for (int k = 0; k < 8; k++) bits[k] = 0u;
            for (int y = 0; y < 16; y++)
            for (int x = 0; x < 16; x++) {
                vec2 uv = mid + h * ((vec2(x, y) + 0.5) / 8.0 - 1.0);
                if (textureLod(gtexture, uv, 0.0).a > 0.5) bits[y >> 1] |= 1u << uint((y & 1) * 16 + x);
            }
            for (int k = 0; k < 8; k++) terrainTris.mask[int(s) * 8 + k] = bits[k];
            return int(s);
        }
        if (prev == key) return int(s);
        s = (s + 1u) & uint(TERRAIN_MASKS_MAX - 1);
    }
    return -1;
}

// la, lb, ld are the vertices' positions on their sprite in 0..1; a
// triangle without a mask slot is opaque
void terrainTrisAdd(int set, ivec3 c, vec3 a, vec3 b, vec3 d, vec2 la, vec2 lb, vec2 ld, int maskSlot) {
    uint slot = atomicAdd(terrainTris.count[set], 1u);
    if (slot >= uint(TERRAIN_TRIS_MAX)) return;
    uint prev = imageAtomicExchange(terrainHeadImg, c, slot + 1u);
    uvec2 qa = uvec2(clamp(la, 0.0, 1.0) * 255.0 + 0.5);
    uvec2 qb = uvec2(clamp(lb, 0.0, 1.0) * 255.0 + 0.5);
    uvec2 qd = uvec2(clamp(ld, 0.0, 1.0) * 255.0 + 0.5);
    uint flags = maskSlot >= 0 ? 1u : 0u;
    terrainTris.tris[slot * 2u] = uvec4(
        terrainPack(a) | (qa.x << 24), terrainPack(b) | (qb.x << 24), terrainPack(d) | (qd.x << 24), prev);
    terrainTris.tris[slot * 2u + 1u] = uvec4(
        qa.y | (qb.y << 8) | (qd.y << 16) | (flags << 24), uint(max(maskSlot, 0)), 0u, 0u);
}
#endif

#ifdef TERRAIN_HEAD_SAMPLER
uniform usampler3D terrainHeadSampler;
uint terrainHead(ivec3 c) { return texelFetch(terrainHeadSampler, c, 0).r; }
#endif

#if defined(TERRAIN_HEAD_IMAGE) || defined(TERRAIN_HEAD_SAMPLER)
// Nearest hit of ro + t * rd, t in (tmin, tmax), against the compacted
// triangles of cell c, or -1. n is the hit's normal facing the ray. A hit
// on a transparent texel of the sprite does not count.
// TERRAIN_OCCLUSION_ONLY returns any opaque hit for nonnegative tmin.
// In that mode n stays zero; intervals crossing zero retain nearest-hit search.
float traceTerrainCell(ivec3 c, vec3 ro, vec3 rd, float tmin, float tmax, out vec3 n) {
    float best = -1.0;
    n = vec3(0.0);
    uint r = terrainHead(c);
    uint count = r >> 18;
    if (count == 0u) return -1.0;
    uint off = r & 0x3FFFFu;
    vec3 base = vec3(c);
    for (uint i = 0u; i < count; i += 4u) {
        // Four records are fetched before any is used, so their latencies
        // overlap; the index is clamped so the fetch stays in the run
        uvec4 A[4];
        for (uint k = 0u; k < 4u; k++) A[k] = terrainTris.ctris[(off + min(i + k, count - 1u)) * 2u];
        for (uint k = 0u; k < 4u; k++) {
            if (i + k >= count) break;
#if DEBUG_VIEW == 14
            traceCost++;
#endif
            vec3 a = base + terrainUnpack(A[k].x);
            vec3 b = base + terrainUnpack(A[k].y);
            vec3 d = base + terrainUnpack(A[k].z);
            vec2 bary;
            float t = rayTriangle(ro, rd, a, b, d, bary);
            if (t > tmin && t < tmax) {
                bool solid = true;
                uvec4 B = terrainTris.ctris[(off + i + k) * 2u + 1u];
                if ((B.x >> 24) != 0u) {
                    vec2 la = vec2(float(A[k].x >> 24), float(B.x & 0xFFu)) / 255.0;
                    vec2 lb = vec2(float(A[k].y >> 24), float((B.x >> 8) & 0xFFu)) / 255.0;
                    vec2 ld = vec2(float(A[k].z >> 24), float((B.x >> 16) & 0xFFu)) / 255.0;
                    vec2 l = la + bary.x * (lb - la) + bary.y * (ld - la);
                    solid = terrainMaskBit(B.y, clamp(ivec2(l * 16.0), ivec2(0), ivec2(15)));
                }
                if (solid) {
                    tmax = t;
                    best = t;
#ifdef TERRAIN_OCCLUSION_ONLY
                    if (tmin >= 0.0) return t;
#else
                    n = cross(b - a, d - a);
#endif
                }
            }
        }
    }
#ifndef TERRAIN_OCCLUSION_ONLY
    if (best > 0.0) {
        n = normalize(n);
        if (dot(n, rd) > 0.0) n = -n;
    }
#endif
    return best;
}
#endif

#endif
