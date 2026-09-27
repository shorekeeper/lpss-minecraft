// Per-voxel pass over the grid after the shadow pass, included by the two
// shadowcomp compute programs with STEP_* switches. Step 1 infers buried
// blocks, owns the per-frame lists, holds entity cells and folds last
// frame's bounce deposits into the bounce volume. Step 2 infers one more
// layer, writes the occluder neighbourhood, bins the player triangles,
// splits the bounce budget between the lamps, compacts the triangle lists,
// copies the bounce volume and zeroes the deposit counters.

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform int frameCounter;

const ivec3 FACE[6] = ivec3[6](
    ivec3( 1, 0, 0), ivec3(-1, 0, 0),
    ivec3( 0, 1, 0), ivec3( 0,-1, 0),
    ivec3( 0, 0, 1), ivec3( 0, 0,-1));

#ifdef STEP_COMPACT_TRIS
#define MESH_RECT_BUILD
#include "/lib/mesh_rect.glsl"
shared uint compactGroup;
shared uint compactBase;
#endif

// Whether the straight line from a lamp to the camera, both in grid index
// space, passes through a full cube; sampled a block apart. Voxels are
// being inferred by other threads of this step, so only cubes the mesh
// gave count: a cave ceiling shows such a cube to the line first anyway.
float lampCameraVisibility(vec3 lamp, vec3 cam) {
    vec3 d = cam - lamp;
    int n = min(int(length(d)), 32);
    if (n < 2) return 1.0;
    vec3 stp = d / float(n);
    for (int i = 1; i < n; i++) {
        ivec3 c = ivec3(floor(lamp + stp * float(i)));
        if (!voxelInside(c)) break;
        uint cv = imageLoad(voxelImg, c).r;
        if (voxelFull(cv) && voxelFromMesh(cv)) return BUDGET_HIDDEN;
    }
    return 1.0;
}

void main() {
#if SKIP_COMPUTE
    // Without the grid steps the light list would hold whatever memory
    // held, and the deferred pass would trace to 512 lamps of garbage
    if (all(equal(gl_GlobalInvocationID, uvec3(0)))) { lightsClear(0); lightsClear(1); }
    return;
#endif
    ivec3 idx = ivec3(gl_GlobalInvocationID);
    if (!voxelInside(idx)) return;

    uint v = imageLoad(voxelImg, idx).r;

    // Blocks the mesh never touched read as zero. One next to a full cube
    // with a culled face towards it is a full opaque cube; each step marks
    // one layer inwards. Inferred voxels show every face, so a thread
    // reading a freshly written one never infers from it, and the result
    // does not depend on thread order.
    // A block buried inside a crown is leaves like the neighbour it is
    // inferred from, so the crown stays translucent through its depth.
    if (v == 0u) {
        for (int k = 0; k < 6; k++) {
            ivec3 n = idx + FACE[k];
            if (!voxelInside(n)) continue;
            uint nv = imageLoad(voxelImg, n).r;
            if (voxelEnclosedBy(nv, k ^ 1)) { v = VOXEL_ENCLOSED | (nv & VOXEL_LEAVES); break; }
        }
        if (v != 0u) imageStore(voxelImg, idx, uvec4(v));
    }

#ifdef STEP_SHIFT
    ivec3 shift = ivec3(floor(cameraPosition)) - ivec3(floor(previousCameraPosition));
#else
    ivec3 shift = ivec3(0);
#endif

#ifdef STEP_LISTS
    // The shadow pass has already filled this frame's triangle set, so the
    // other sets are free to clear for the next frame; this frame's
    // emitters go into the light list and the triangle bins are emptied for
    // step 2.
    if (all(equal(idx, ivec3(0)))) {
        entityTrisFrameStart(entityTriSet(frameCounter));
        terrainTrisClear(1 - terrainTriSet(frameCounter));
        terrainTris.compactCount = 0u;
    }
    if (idx.z == 0) {
        int lin = idx.x + idx.y * VOXEL_SIZE;
        entityBinsClear(lin);
        terrainMasksClear(1 - terrainTriSet(frameCounter), lin);
    }
    if (idx.z < 4) terrainDedupClear(1 - terrainTriSet(frameCounter), idx.x + (idx.y + idx.z * VOXEL_SIZE) * VOXEL_SIZE);
#if LAMP_CLUSTER == 1
    if (voxelEmission(v) > 0) {
        vec3 camGrid = cameraPosition - vec3(voxelOrigin(cameraPosition));
        float vis = lampCameraVisibility(vec3(idx) + voxelLampOffset(v), camGrid);
        lightsAdd(lightSet(frameCounter), idx, v, vis, camGrid);
    }
#else
    // The thread of a world-aligned cluster cell's base gathers the
    // emitters of the cell, one lamp per colour class: the lamp sits at
    // the mean of the members' positions, the emission is the largest, the
    // count scales the strength. Emission bits are never inferred, so
    // reading neighbours while they are being inferred is safe.
    {
        ivec3 origin = voxelOrigin(cameraPosition);
        if (all(equal((idx + origin) & (LAMP_CLUSTER - 1), ivec3(0)))) {
            vec3 camGrid = cameraPosition - vec3(origin);
            for (int cc = 0; cc < 4; cc++) {
                vec3 sum = vec3(0.0);
                uint base = 0u;
                int n = 0;
                int em = 0;
                for (int k = 0; k < 8; k++) {
                    ivec3 c = idx + ivec3(k & 1, (k >> 1) & 1, (k >> 2) & 1);
                    if (!voxelInside(c)) continue;
                    uint cv = k == 0 ? v : imageLoad(voxelImg, c).r;
                    if (voxelEmission(cv) == 0 || voxelColorClass(cv) != cc) continue;
                    sum += vec3(c - idx) + voxelLampOffset(cv);
                    em = max(em, voxelEmission(cv));
                    base = cv;
                    n++;
                }
                if (n == 0) continue;
                uint cl = (base & 0x7Fu & ~(15u << 1)) | (uint(em) << 1) | lampClusterPack(sum / float(n)) | LAMP_CLUSTER_BIT | (uint(n - 1) << 29);
                float vis = lampCameraVisibility(lampPosition(uvec4(uvec3(idx), cl)), camGrid);
                lightsAdd(lightSet(frameCounter), idx, cl, vis, camGrid);
            }
        }
    }
#endif
#endif

#ifdef STEP_ENTITY_HOLD
    // An entity cell stays a cube one frame past its last sighting, so a
    // mesh the shadow pass drops for a frame does not flicker, see
    // lib/entity_age.glsl
    {
        ivec3 s = idx + shift;
        int set = frameCounter & 1;
        uint age = 0u;
        if (voxelEntity(v)) {
            age = 2u;
        } else if (!voxelFillsCentre(v) && voxelInside(s)) {
            if (entityAge.age[entityAgeIndex(1 - set, s)] == 2u) {
                age = 1u;
                v |= VOXEL_ENTITY;
                imageStore(voxelImg, idx, uvec4(v));
            }
        }
        entityAge.age[entityAgeIndex(set, idx)] = age;
    }
#endif

#ifdef STEP_BOUNCE_BLEND
    // Deposits and the previous volume both belong to last frame's grid.
    // The new frame's weight falls with the frames the cell has
    // accumulated, see lib/history.glsl; a reset flag shadowcomp_c wrote
    // last frame, for a change nearby, starts the count over. Filled cells
    // are never sampled and hold nothing; the cap keeps a counter that
    // came in unzeroed from flashing through the volume.
    {
        ivec3 s = idx + shift;
        vec3 cur = vec3(0.0);
        vec4 prev = vec4(0.0);
        bool reset = false;
        if (voxelInside(s)) {
            cur = bounceDecode(uvec3(imageLoad(bounceAccR, s).r, imageLoad(bounceAccG, s).r, imageLoad(bounceAccB, s).r));
            prev = imageLoad(bounceImgA, s);
            reset = ((frameCounter & 1) == 0 ? imageLoad(resetImgB, s).r : imageLoad(resetImgA, s).r) != 0u;
        }
        float n = reset ? 0.0 : historyCount(prev.a);
        if (voxelFillsCentre(v)) { cur = vec3(0.0); prev.rgb = vec3(0.0); n = 0.0; }
        cur = min(cur, vec3(64.0));
        imageStore(bounceImgB, idx, vec4(mix(prev.rgb, cur, historyWeight(n, BOUNCE_TEMPORAL)), n + 1.0));
    }
#endif

#ifdef STEP_RAY_BUDGET
    // The light list is complete after step 1, so one thread can split the
    // bounce budget between its lamps for shadowcomp_b
    if (all(equal(idx, ivec3(0)))) lightsBudget(lightSet(frameCounter), BOUNCE_THREADS);
#endif

#ifdef STEP_NEAR_MASK
    // The voxels are final after step 1's inference, so the trace's
    // neighbourhood can be summed up once, bits as in lib/near.glsl
    {
        uint m = 0u;
        if (voxelCube(v)) m |= 0x80u; else if (voxelOccluder(v)) m |= 0x40u;
        for (int k = 0; k < 6; k++) {
            ivec3 n = idx + FACE[k];
            if (!voxelInside(n)) continue;
            uint nv = imageLoad(voxelImg, n).r;
            if (voxelLeaves(nv) && voxelFull(nv)) m |= 1u << uint(16 + k);
            else if (voxelCube(nv)) m |= 1u << uint(k);
            else if (voxelOccluder(nv)) m |= 1u << uint(8 + k);
        }
        // Cubes at the edges and corners gate the diagonal scan of the
        // trace; a cube is never crossed and needs none
        if (!voxelCube(v)) {
            for (int z = -1; z <= 1; z++)
            for (int y = -1; y <= 1; y++)
            for (int x = -1; x <= 1; x++) {
                if (abs(x) + abs(y) + abs(z) < 2) continue;
                ivec3 n = idx + ivec3(x, y, z);
                if (!voxelInside(n)) continue;
                uint nv = imageLoad(voxelImg, n).r;
                if (voxelCube(nv) && !voxelLeaves(nv)) m |= 1u << 23;
            }
        }
        voxelNear.cell[nearIndex(idx)] = uvec2(m, v);
    }
#endif

#ifdef STEP_COMPACT_TRIS
    // Each cell's list is walked once to count, the group claims one run of
    // ctris for all its cells, and the list is walked again to copy; the
    // head is then replaced by the run's offset and count, see
    // lib/terrain_tris.glsl. The dispatch covers the grid exactly, so every
    // invocation of the group reaches the barriers.
    {
        if (gl_LocalInvocationIndex == 0u) compactGroup = 0u;
        barrier();
        uint head = terrainHead(idx);
        uint n = 0u;
        for (uint i = head; i != 0u && n < 4096u; n++) i = terrainTris.tris[(i - 1u) * 2u].w;
        uint local = n > 0u ? atomicAdd(compactGroup, n) : 0u;
        barrier();
        if (gl_LocalInvocationIndex == 0u) {
            compactBase = compactGroup > 0u ? atomicAdd(terrainTris.compactCount, compactGroup) : 0u;
        }
        barrier();
        uint off = compactBase + local;
        uint stored = 0u;
        for (uint i = head; i != 0u && stored < n; stored++) {
            if (off + stored >= uint(TERRAIN_TRIS_MAX)) break;
            uvec4 A = terrainTris.tris[(i - 1u) * 2u];
            terrainTris.ctris[(off + stored) * 2u] = A;
            uvec4 B = terrainTris.tris[(i - 1u) * 2u + 1u];
            if ((B.x >> 24) != 0u) {
                uint opacityBits = 0xFFFFFFFFu;
                for (int wordIndex = 0; wordIndex < 8; wordIndex++) {
                    opacityBits &= terrainTris.mask[int(B.y) * 8 + wordIndex];
                }
                if (opacityBits == 0xFFFFFFFFu) B.x &= 0x00FFFFFFu;
            }
            terrainTris.ctris[(off + stored) * 2u + 1u] = B;
            i = A.w;
        }
        meshRectBuild(off, stored);
        imageStore(
            terrainHeadImg, idx, uvec4(terrainRange(off, stored)));
    }
#endif

#ifdef STEP_BIN_ENTITIES
    // One thread per captured triangle
    if (idx.z == 0) {
        int set = entityTriSet(frameCounter);
        int lin = idx.x + idx.y * VOXEL_SIZE;
        if (lin < int(entityTriCount(set))) entityTrisBin(set, uint(lin));
    }
#endif

#ifdef STEP_LAMP_BINS
    // One thread per bin
    if (idx.z == 1) {
        int lin = idx.x + idx.y * VOXEL_SIZE;
        if (lin < LAMP_BIN_CELLS) lampBinGather(lightSet(frameCounter), lin);
    }
#endif

#ifdef STEP_GUIDE
    // One thread per lamp: finds or claims the lamp's tree by its world
    // position, folds last frame's deposits in and rebuilds it
    if (idx.z == 2) {
        int set = lightSet(frameCounter);
        int lin = idx.x + idx.y * VOXEL_SIZE;
        if (lin < int(lightCount(set))) {
#if GUIDE_ENABLED
            uvec4 L = lightList.lights[set * LIGHTS_MAX + lin];
            ivec3 wp = ivec3(L.xyz) + voxelOrigin(cameraPosition);
            bool fresh;
            int slot = guideSlotClaim(wp, uint(frameCounter), fresh);
            lightList.guideSlot[set * LIGHTS_MAX + lin] = slot < 0 ? GUIDE_NONE : uint(slot);
            if (slot >= 0) guideRebuild(slot, uint(frameCounter), fresh);
#else
            lightList.guideSlot[set * LIGHTS_MAX + lin] = GUIDE_NONE;
#endif
        }
    }
#endif

#ifdef STEP_BOUNCE_COPY
    imageStore(bounceImgA, idx, imageLoad(bounceImgB, idx));
    imageStore(bounceAccR, idx, uvec4(0u));
    imageStore(bounceAccG, idx, uvec4(0u));
    imageStore(bounceAccB, idx, uvec4(0u));
#endif
}

