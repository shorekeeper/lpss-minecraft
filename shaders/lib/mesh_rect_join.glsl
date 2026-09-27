#ifndef MESH_RECT_JOIN_GLSL
#define MESH_RECT_JOIN_GLSL
#include "/lib/terrain_tris.glsl"

// Axis-aligned rectangle bounds in grid-space units of 1/64.
bool meshRectJoinBounds(
    uvec4 recordA, ivec3 cell,
    out ivec3 low, out ivec3 high, out int normalAxis
) {
    uvec3 keys = recordA.xyz & 0xFFFFFFu;
    ivec3 a = ivec3(keys.x & 255u, (keys.x >> 8) & 255u, (keys.x >> 16) & 255u);
    ivec3 b = ivec3(keys.y & 255u, (keys.y >> 8) & 255u, (keys.y >> 16) & 255u);
    ivec3 d = ivec3(keys.z & 255u, (keys.z >> 8) & 255u, (keys.z >> 16) & 255u);

    low = min(a, min(b, d));
    high = max(a, max(b, d));
    ivec3 extent = high - low;

    normalAxis = -1;
    if (extent.x == 0 && extent.y > 0 && extent.z > 0) normalAxis = 0;
    else if (extent.y == 0 && extent.x > 0 && extent.z > 0) normalAxis = 1;
    else if (extent.z == 0 && extent.x > 0 && extent.y > 0) normalAxis = 2;
    if (normalAxis < 0) return false;

    if (any(notEqual((a - low) * (high - a), ivec3(0))) ||
        any(notEqual((b - low) * (high - b), ivec3(0))) ||
        any(notEqual((d - low) * (high - d), ivec3(0)))) return false;

    ivec3 shift = cell * 64 - ivec3(32);
    low += shift;
    high += shift;
    return true;
}

// Extend along one rectangle axis through directly touching or
// overlapping coplanar rectangles of the same transverse extent.
// Every comparison uses the original bounds, independent of list order.
uint meshRectJoinBits(uvec4 recordA, ivec3 sourceCell) {
    ivec3 sourceLow, sourceHigh;
    int normalAxis;
    if (!meshRectJoinBounds(
        recordA, sourceCell, sourceLow, sourceHigh, normalAxis)) return 0u;

    int u = normalAxis == 0 ? 1 : 0;
    int v = normalAxis == 2 ? 1 : 2;
    int lowU = sourceLow[u];
    int highU = sourceHigh[u];
    int lowV = sourceLow[v];
    int highV = sourceHigh[v];

    for (int neighbour = 0; neighbour < 5; neighbour++) {
        ivec3 cell = sourceCell;
        if (neighbour > 0) {
            int axis = neighbour <= 2 ? u : v;
            cell[axis] += (neighbour & 1) != 0 ? 1 : -1;
        }
        if (!voxelInside(cell)) continue;

        uint range = terrainHead(cell);
        uint count = range >> 18;
        if (count == 0u) continue;

        uint off = range & 0x3FFFFu;
        uint member = terrainTris.ctris[off * 2u + 1u].w;

        for (uint guard = 0u; guard < count && member != 0u; guard++) {
            uint index = member - 1u;
            uvec4 otherA = terrainTris.ctris[index * 2u];
            member = terrainTris.ctris[index * 2u + 1u].z;

            ivec3 low, high;
            int otherAxis;
            if (!meshRectJoinBounds(otherA, cell, low, high, otherAxis)) continue;
            if (otherAxis != normalAxis ||
                low[normalAxis] != sourceLow[normalAxis]) continue;

            if (low[v] == sourceLow[v] && high[v] == sourceHigh[v] &&
                high[u] >= sourceLow[u] && low[u] <= sourceHigh[u]) {
                lowU = min(lowU, low[u]);
                highU = max(highU, high[u]);
            }

            if (low[u] == sourceLow[u] && high[u] == sourceHigh[u] &&
                high[v] >= sourceLow[v] && low[v] <= sourceHigh[v]) {
                lowV = min(lowV, low[v]);
                highV = max(highV, high[v]);
            }
        }
    }

    ivec4 growth = clamp(ivec4(
        sourceLow[u] - lowU, highU - sourceHigh[u],
        sourceLow[v] - lowV, highV - sourceHigh[v]), 0, 255);

    // Extending both axes independently could fill missing corners.
    // Keep the larger of the two valid rectangular unions.
    int areaU = (growth.x + growth.y) * (sourceHigh[v] - sourceLow[v]);
    int areaV = (growth.z + growth.w) * (sourceHigh[u] - sourceLow[u]);
    if (areaU >= areaV) growth.zw = ivec2(0);
    else growth.xy = ivec2(0);

    uvec4 bits = uvec4(growth);
    return bits.x | (bits.y << 8) | (bits.z << 16) | (bits.w << 24);
}

// Runs after compaction. Only B.y is written. Geometry, kinds and links
// remain immutable while other cells inspect them.
void meshRectJoinCell(ivec3 cell) {
    uint range = terrainHead(cell);
    uint count = range >> 18;
    if (count == 0u) return;

    uint off = range & 0x3FFFFu;
    uint member = terrainTris.ctris[off * 2u + 1u].w;
    for (uint guard = 0u; guard < count && member != 0u; guard++) {
        uint index = member - 1u;
        uvec4 recordA = terrainTris.ctris[index * 2u];
        uint next = terrainTris.ctris[index * 2u + 1u].z;

        terrainTris.ctris[index * 2u + 1u].y =
            meshRectJoinBits(recordA, cell);
        member = next;
    }
}

#endif