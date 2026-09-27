#ifndef SKYVOL_GLSL
#define SKYVOL_GLSL
#include "/lib/settings.glsl"
#include "/lib/voxel.glsl"

// Sky visibility on the grid, written by shadowcomp_e.csh and read by the
// deferred pass. A cell holds the linear moments of the cosine-weighted
// rays it sees the sky through, share and mean direction, and the number
// of rays they run over, in two sets by frame parity: the pass reads last
// frame's set at the shifted position and writes this frame's. The
// moments are four unorm16 in a uvec2. A buffer rather than images: the
// loader allows sixteen custom images and drops the rest with a line in
// the log only, and the pack holds fourteen.

const int SKY_CELLS = VOXEL_SIZE * VOXEL_SIZE * VOXEL_SIZE;

layout(std430, binding = 7) buffer SkyVol {
    uvec2 moments[2 * SKY_CELLS];
    uint count[];
} skyVol;

int skySet(int frame) { return frame & 1; }
int skyIndex(int set, ivec3 c) { return set * SKY_CELLS + (c.z * VOXEL_SIZE + c.y) * VOXEL_SIZE + c.x; }

uint skyQ16(float x) { return uint(clamp(x, 0.0, 1.0) * 65535.0 + 0.5); }
float skyF16(uint q) { return float(q & 0xFFFFu) / 65535.0; }

uvec2 skyPack(vec4 m) {
    return uvec2(skyQ16(m.x * 0.5 + 0.5) | (skyQ16(m.y * 0.5 + 0.5) << 16),
                 skyQ16(m.z * 0.5 + 0.5) | (skyQ16(m.a) << 16));
}

vec4 skyUnpack(uvec2 p) {
    return vec4(skyF16(p.x) * 2.0 - 1.0, skyF16(p.x >> 16) * 2.0 - 1.0,
                skyF16(p.y) * 2.0 - 1.0, skyF16(p.y >> 16));
}

// The count word holds the rays in its low half and the resets the cell
// has been through in its high half
vec4 skyMoments(int set, ivec3 c) { return skyUnpack(skyVol.moments[skyIndex(set, c)]); }
uint skyCount(int set, ivec3 c) { return skyVol.count[skyIndex(set, c)] & 0xFFFFu; }
uint skyResets(int set, ivec3 c) { return skyVol.count[skyIndex(set, c)] >> 16; }

void skyStore(int set, ivec3 c, vec4 m, uint n, uint resets) {
    int i = skyIndex(set, c);
    skyVol.moments[i] = skyPack(m);
    skyVol.count[i] = (n & 0xFFFFu) | (min(resets, 0xFFFFu) << 16);
}

#endif