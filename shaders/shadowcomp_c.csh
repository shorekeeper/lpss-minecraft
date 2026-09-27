#version 430
#include "/lib/settings.glsl"
#include "/lib/voxel.glsl"
#include "/lib/lights.glsl"
#include "/lib/history.glsl"
#include "/lib/near.glsl"
#define TERRAIN_HEAD_IMAGE
#include "/lib/mesh_rect_join.glsl"

// Change detection for the temporal volumes, see lib/history.glsl. Runs
// once the grid is final: every voxel's classification is compared with
// last frame's at the shifted position and written for next frame, and a
// change flags the cells around it. Lamps are compared through the light
// list, whose positions are real from the first frame, while the
// classification images start with whatever memory held: a lamp that
// entered or left the list flags a sphere of its reach. The flag set of
// the other parity, read by the first grid step this frame, is cleared
// here for next frame.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
const ivec3 workGroups = ivec3(16, 16, 16);

layout(r32ui) uniform readonly uimage3D voxelImg;
layout(r8ui)  uniform uimage3D voxelClassImgA;
layout(r8ui)  uniform uimage3D voxelClassImgB;
layout(r8ui)  uniform writeonly uimage3D resetImgA;
layout(r8ui)  uniform writeonly uimage3D resetImgB;

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform int frameCounter;

// why is 1 for a voxel class change, 2 for a lamp; the readers only test
// for nonzero
void flag(ivec3 c, uint why) {
    if (!voxelInside(c)) return;
    if ((frameCounter & 1) == 0) imageStore(resetImgA, c, uvec4(why)); else imageStore(resetImgB, c, uvec4(why));
}

void flagBox(ivec3 c, int r) {
    for (int z = -r; z <= r; z++)
    for (int y = -r; y <= r; y++)
    for (int x = -r; x <= r; x++) flag(c + ivec3(x, y, z), 1u);
}

void flagSphere(ivec3 c, int r) {
    for (int z = -r; z <= r; z++)
    for (int y = -r; y <= r; y++)
    for (int x = -r; x <= r; x++) {
        if (x * x + y * y + z * z > r * r) continue;
        flag(c + ivec3(x, y, z), 2u);
    }
}

// Whether set holds a lamp at grid index c of that set's frame
bool lampListed(int set, ivec3 c) {
    uint n = lightCount(set);
    for (uint i = 0u; i < n; i++) {
        if (all(equal(ivec3(lightList.lights[set * LIGHTS_MAX + int(i)].xyz), c))) return true;
    }
    return false;
}

void main() {
#if SKIP_COMPUTE
    return;
#endif
    ivec3 idx = ivec3(gl_GlobalInvocationID);
    if (!voxelInside(idx)) return;

    ivec3 shift = ivec3(floor(cameraPosition)) - ivec3(floor(previousCameraPosition));
    bool even = (frameCounter & 1) == 0;
    int set = lightSet(frameCounter);

    if (even) imageStore(resetImgB, idx, uvec4(0u)); else imageStore(resetImgA, idx, uvec4(0u));

    // One thread per lamp of either list. A lamp of this frame with no
    // counterpart last frame entered; one of last frame with no
    // counterpart now left, and its position is brought into this frame's
    // grid.
    if (idx.z == 0) {
        int lin = idx.x + idx.y * VOXEL_SIZE;
        if (lin < int(lightCount(set))) {
            ivec3 c = ivec3(lightList.lights[set * LIGHTS_MAX + lin].xyz);
            if (!lampListed(1 - set, c + shift)) flagSphere(c, int(LPV_RANGE));
        } else if (lin >= VOXEL_SIZE * VOXEL_SIZE / 2 && lin - VOXEL_SIZE * VOXEL_SIZE / 2 < int(lightCount(1 - set))) {
            int j = lin - VOXEL_SIZE * VOXEL_SIZE / 2;
            ivec3 c = ivec3(lightList.lights[(1 - set) * LIGHTS_MAX + j].xyz) - shift;
            if (voxelInside(c) && !lampListed(set, c)) flagSphere(c, int(LPV_RANGE));
        }
    }

    uint currentVoxel = imageLoad(voxelImg, idx).r;
    if (voxelPartial(currentVoxel)) {
        // A cell holding rectangle leaders marks its 26 neighbours, whose
        // traces then scan for it, see bit 22 of lib/near.glsl
        uint range = terrainHead(idx);
        if ((range >> 18) != 0u && terrainTris.ctris[(range & 0x3FFFFu) * 2u + 1u].w != 0u) {
            for (int z = -1; z <= 1; z++)
            for (int y = -1; y <= 1; y++)
            for (int x = -1; x <= 1; x++) {
                ivec3 n = idx + ivec3(x, y, z);
                if (all(equal(n, idx)) || !voxelInside(n)) continue;
                atomicOr(voxelNear.cell[nearIndex(n)].x, NEAR_RECT_AROUND);
            }
        }
        meshRectJoinCell(idx);
    }
    uint cls = voxelClass(currentVoxel);
    ivec3 s = idx + shift;
    uint prev = cls;
    if (voxelInside(s)) prev = even ? imageLoad(voxelClassImgB, s).r : imageLoad(voxelClassImgA, s).r;
    if (even) imageStore(voxelClassImgA, idx, uvec4(cls)); else imageStore(voxelClassImgB, idx, uvec4(cls));

    if (cls != prev) flagBox(idx, RESET_RADIUS);
}
