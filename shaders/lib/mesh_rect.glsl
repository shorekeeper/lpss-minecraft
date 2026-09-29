#ifndef MESH_RECT_GLSL
#define MESH_RECT_GLSL
#include "/lib/terrain_tris.glsl"

#ifdef MESH_RECT_BUILD

uvec3 meshRectSort(uvec3 p) {
    uint low = min(p.x, min(p.y, p.z));
    uint high = max(p.x, max(p.y, p.z));
    return uvec3(low, p.x ^ p.y ^ p.z ^ low ^ high, high);
}

ivec3 meshRectPoint(uint p) {
    return ivec3(p & 255u, (p >> 8) & 255u, (p >> 16) & 255u);
}

int meshRectLength2(ivec3 p) {
    return p.x * p.x + p.y * p.y + p.z * p.z;
}

// Recognize a right triangle and construct the other half of its rectangle.
bool meshRectCandidate(
    uvec3 vertices, out uint cornerIndex, out uint cornerKey,
    out uint fourthKey, out uvec3 wanted
) {
    ivec3 p0 = meshRectPoint(vertices.x);
    ivec3 p1 = meshRectPoint(vertices.y);
    ivec3 p2 = meshRectPoint(vertices.z);
    int length01 = meshRectLength2(p1 - p0);
    int length12 = meshRectLength2(p2 - p1);
    int length20 = meshRectLength2(p0 - p2);
    if (length01 == 0 || length12 == 0 || length20 == 0) return false;

    uint diagonal0;
    uint diagonal1;
    ivec3 corner;

    if (length01 >= length12 && length01 >= length20) {
        if (length01 != length12 + length20) return false;
        diagonal0 = vertices.x;
        diagonal1 = vertices.y;
        corner = p2;
        cornerIndex = 3u;
        cornerKey = vertices.z;
    } else if (length12 >= length20) {
        if (length12 != length01 + length20) return false;
        diagonal0 = vertices.y;
        diagonal1 = vertices.z;
        corner = p0;
        cornerIndex = 1u;
        cornerKey = vertices.x;
    } else {
        if (length20 != length01 + length12) return false;
        diagonal0 = vertices.z;
        diagonal1 = vertices.x;
        corner = p1;
        cornerIndex = 2u;
        cornerKey = vertices.y;
    }

    ivec3 fourth = p0 + p1 + p2 - 2 * corner;
    if (any(lessThan(fourth, ivec3(0))) ||
        any(greaterThan(fourth, ivec3(255)))) return false;

    fourthKey = uint(fourth.x) |
        (uint(fourth.y) << 8) | (uint(fourth.z) << 16);
    wanted = meshRectSort(uvec3(diagonal0, diagonal1, fourthKey));
    return true;
}

// Metadata in compacted records:
// A.w: 0 opaque triangle, 1..3 rectangle corner, 4 paired half, 8 alpha.
// B.y of rectangle leaders: four 8-bit join extensions after shadowcomp_c.
// B.z: next rectangle record plus one.
// B.w of the cell's first record: first rectangle record plus one.
// Triangle positions remain intact for hard ray tests.
void meshRectBuild(uint off, uint count) {
    if (count == 0u) return;

    uint first = 0u;
    for (uint i = 0u; i < count; i++) {
        uint index = off + i;
        uvec4 recordA = terrainTris.ctris[index * 2u];
        uvec4 recordB = terrainTris.ctris[index * 2u + 1u];

        recordA.w = (recordB.x >> 24) != 0u ? 8u : 0u;
        recordB.z = 0u;
        recordB.w = 0u;

        if (recordA.w == 0u) {
            uint cornerIndex, cornerKey, fourthKey;
            uvec3 wanted;
            if (meshRectCandidate(
                recordA.xyz & 0xFFFFFFu,
                cornerIndex, cornerKey, fourthKey, wanted)) {
                bool paired = false;

                for (uint j = 0u; j < count; j++) {
                    uvec4 otherA = terrainTris.ctris[(off + j) * 2u];
                    if (!all(equal(
                        meshRectSort(otherA.xyz & 0xFFFFFFu), wanted))) continue;

                    uvec4 otherB = terrainTris.ctris[(off + j) * 2u + 1u];
                    if ((otherB.x >> 24) == 0u) {
                        paired = true;
                        break;
                    }
                }

                if (paired) {
                    if (cornerKey < fourthKey) {
                        recordA.w = cornerIndex;
                        recordB.z = first;
                        first = index + 1u;
                    } else {
                        recordA.w = 4u;
                    }
                }
            }
        }

        terrainTris.ctris[index * 2u] = recordA;
        terrainTris.ctris[index * 2u + 1u] = recordB;
    }

    uvec4 firstB = terrainTris.ctris[off * 2u + 1u];
    firstB.w = first;
    terrainTris.ctris[off * 2u + 1u] = firstB;
}

#else

// Fraction of a uniform disc on the positive side of a line.
// Circular segment area uses a polynomial approximation.
// Empty and full coverage use the exact disc support.
float meshRectDiscFraction(float forward, float radius) {
    if (forward >= radius) return 1.0;
    if (forward <= -radius) return 0.0;

    float x = abs(forward) / radius;
    float tail = 1.0 - x;
    float cap = tail * sqrt(tail) *
        (0.5 + x * (0.113380228 +
            x * (-0.016159456 + x * 0.002990106)));

    return forward >= 0.0 ? 1.0 - cap : cap;
}

// Projective edge plane through the receiver.
// Its intersection with the source plane is a straight line.
float meshRectEdgeFraction(vec3 edgeNormal, vec3 rd, float k) {
    float forward = dot(edgeNormal, rd);
    vec3 lateral = edgeNormal - rd * forward;
    return meshRectDiscFraction(forward, k * length(lateral));
}

// Opposite edge pairs form two projected strips on the source disc.
// Their intersection and source-depth clipping use a separable estimate,
// which overestimates a thin occluder through the disc centre by up to
// 4 / pi; the exact area of the projected quad was measured to remove
// that and to multiply the compile time of every program holding the
// walk by thirty.
float meshRectCoverage(
    uvec4 recordA, uint joinBits, vec3 base, vec3 rd, float k
) {
    uint kind = recordA.w;
    uint originKey = kind == 1u ? recordA.x :
        (kind == 2u ? recordA.y : recordA.z);
    uint uKey = kind == 1u ? recordA.y : recordA.x;
    uint vKey = kind == 3u ? recordA.y : recordA.z;

    vec3 corner = terrainUnpack(originKey);
    vec3 edgeU = terrainUnpack(uKey) - corner;
    vec3 edgeV = terrainUnpack(vKey) - corner;

    if (joinBits != 0u) {
        vec3 opposite = corner + edgeU + edgeV;
        vec3 low = min(corner, opposite);
        vec3 high = max(corner, opposite);
        int normalAxis = low.x == high.x ? 0 : (low.y == high.y ? 1 : 2);
        int u = normalAxis == 0 ? 1 : 0;
        int v = normalAxis == 2 ? 1 : 2;

        vec4 growth = vec4(uvec4(
            joinBits, joinBits >> 8, joinBits >> 16, joinBits >> 24) & 255u) / 64.0;
        low[u] -= growth.x;
        high[u] += growth.y;
        low[v] -= growth.z;
        high[v] += growth.w;

        corner = low;
        edgeU = vec3(0.0);
        edgeV = vec3(0.0);
        edgeU[u] = high[u] - low[u];
        edgeV[v] = high[v] - low[v];
    }

    vec3 origin = base + corner;

    vec3 plane = cross(edgeU, edgeV);
    if (dot(plane, plane) < 1e-12) return 0.0;

    float signedDistance = dot(plane, origin);
    if (abs(signedDistance) < 1e-12) return 0.0;
    if (signedDistance < 0.0) plane = -plane;
    float distance = abs(signedDistance);

    float rayLength = LAMP_RADIUS / max(k, 1e-20);
    float forward = dot(plane, rd);
    vec3 lateral = plane - rd * forward;
    float sourceCoverage = meshRectDiscFraction(
        forward - distance / rayLength,
        k * length(lateral));
    if (sourceCoverage <= 0.0) return 0.0;

    vec3 gradU = edgeU / dot(edgeU, edgeU);
    vec3 gradV = edgeV / dot(edgeV, edgeV);

    vec3 lowerU = distance * gradU - dot(gradU, origin) * plane;
    float u0 = meshRectEdgeFraction(lowerU, rd, k);
    if (u0 <= 0.0) return 0.0;
    float u1 = meshRectEdgeFraction(plane - lowerU, rd, k);
    float coverageU = clamp(u0 + u1 - 1.0, 0.0, 1.0);
    if (coverageU <= 0.0) return 0.0;

    vec3 lowerV = distance * gradV - dot(gradV, origin) * plane;
    float v0 = meshRectEdgeFraction(lowerV, rd, k);
    if (v0 <= 0.0) return 0.0;
    float v1 = meshRectEdgeFraction(plane - lowerV, rd, k);
    float coverageV = clamp(v0 + v1 - 1.0, 0.0, 1.0);

    return coverageU * coverageV * sourceCoverage;
}

// Outward normal of a rectangle from its vertex order, which the mesh
// keeps in agreement with the vertex normal and the record keeps intact;
// its axis is the dominant component, 3 off any axis plane
vec3 meshRectNormal(uvec4 recordA, out int axis) {
    vec3 p0 = terrainUnpack(recordA.x);
    vec3 n = cross(terrainUnpack(recordA.y) - p0, terrainUnpack(recordA.z) - p0);
    vec3 an = abs(n);
    float m = max(an.x, max(an.y, an.z));
    if (m < 0.999 * length(n)) axis = 3;
    else axis = an.x == m ? 0 : (an.y == m ? 1 : 2);
    return n;
}

// Only faces turned towards the receiver count: those of one convex box
// project onto regions of the source that meet at its edges without
// overlap, so their sum is the box's silhouette, while a face turned away
// lies behind one of them. Faces sharing an axis take the maximum, for
// two boxes in one cell. The rectangle list contains one half of each
// recognized pair.
float meshRectCellVisibility(
    ivec3 c, vec3 ro, vec3 rd, float k
) {
    uint range = terrainHead(c);
    uint count = range >> 18;
    if (count == 0u) return 1.0;

    uint off = range & 0x3FFFFu;
    uint member = terrainTris.ctris[off * 2u + 1u].w;
    if (member == 0u) return 1.0;

    vec3 base = vec3(c) - ro;
    vec4 axisCoverage = vec4(0.0);
    for (uint guard = 0u; guard < count && member != 0u; guard++) {
        uint index = member - 1u;
        uvec4 recordA = terrainTris.ctris[index * 2u];
#if DEBUG_VIEW == 14
        traceCost++;
#endif
        uvec4 recordB = terrainTris.ctris[index * 2u + 1u];
        member = recordB.z;
        int axis;
        vec3 n = meshRectNormal(recordA, axis);
        if (dot(n, base + terrainUnpack(recordA.x)) >= 0.0) continue;
        float cov = meshRectCoverage(recordA, recordB.y, base, rd, k);
        axisCoverage[axis] = max(axisCoverage[axis], cov);
        if (dot(axisCoverage, vec4(1.0)) >= 1.0) return 0.0;
    }

    return 1.0 - dot(axisCoverage, vec4(1.0));
}

// Neighbouring partial cells touched by the cone.
// Full cubes and alpha masks retain their separate paths.
float meshRectNeighbours(
    vec3 a, vec3 rd, float t0, float t1, float k,
    ivec3 cell, uint mask, ivec3 lampCell, float visibility
) {
    if (visibility <= 0.0 || t1 <= t0) return visibility;
    if (!nearRectAround(mask)) return visibility;

    float radius = k * t1;
    vec3 localA = a - vec3(cell);
    vec3 p0 = clamp(localA + rd * t0, 0.0, 1.0);
    vec3 p1 = clamp(localA + rd * t1, 0.0, 1.0);
    ivec3 lower = -ivec3(lessThan(min(p0, p1), vec3(radius)));
    ivec3 upper = ivec3(lessThan(
        1.0 - max(p0, p1), vec3(radius)));

    for (int z = lower.z; z <= upper.z; z++)
    for (int y = lower.y; y <= upper.y; y++)
    for (int x = lower.x; x <= upper.x; x++) {
        int directions = abs(x) + abs(y) + abs(z);
        if (directions == 0) continue;

        ivec3 offset = ivec3(x, y, z);
        ivec3 nb = cell + offset;
        if (!voxelInside(nb) || all(equal(nb, lampCell))) continue;

        if (directions == 1) {
            int axis = x != 0 ? 0 : (y != 0 ? 1 : 2);
            int face = axis * 2 + (offset[axis] > 0 ? 0 : 1);
            if (!nearPartial(mask, face)) continue;
        }

        vec3 side = vec3(offset);
        vec3 axisMask = abs(side);
        vec3 gap0 = (0.5 + side * (0.5 - p0)) * axisMask;
        vec3 gap1 = (0.5 + side * (0.5 - p1)) * axisMask;
        vec3 gap = min(gap0, gap1);
        if (dot(gap, gap) >= radius * radius) continue;

        uvec2 nc = nearCell(nb);
#if DEBUG_VIEW == 14
        traceCost++;
#endif
        if (!nearSelfPartial(nc.x)) continue;

        vec3 lo, hi;
        voxelSpan(nc.y, lo, hi);
        if (!raySegmentBox(
            a, rd, t0, t1,
            vec3(nb) + lo - radius,
            vec3(nb) + hi + radius)) continue;

        visibility = min(visibility, meshRectCellVisibility(nb, a, rd, k));
        if (visibility <= 0.0) return 0.0;
    }

    return visibility;
}

#endif
#endif