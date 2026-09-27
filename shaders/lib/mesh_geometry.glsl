#ifndef MESH_GEOMETRY_GLSL
#define MESH_GEOMETRY_GLSL
#include "/lib/terrain_tris.glsl"

// Canonical position order excludes UV bytes and winding.
uvec3 meshCanonical(uvec4 recordA) {
    uvec3 p = recordA.xyz & 0xFFFFFFu;
    uint low = min(p.x, min(p.y, p.z));
    uint high = max(p.x, max(p.y, p.z));
    return uvec3(low, p.x ^ p.y ^ p.z ^ low ^ high, high);
}

#ifdef MESH_GEOMETRY_BUILD

bool meshSamePlane(vec3 p, vec3 normal, uvec3 other) {
    vec3 a = terrainUnpack(other.x);
    vec3 b = terrainUnpack(other.y);
    vec3 d = terrainUnpack(other.z);
    vec3 n = cross(b - a, d - a);
    float n2 = dot(n, n);
    float normal2 = dot(normal, normal);
    if (n2 < 1e-12 || normal2 < 1e-12) return false;

    float alignment = dot(normal, n);
    if (alignment * alignment < 0.99999 * normal2 * n2) return false;

    float separation = dot(normal, a - p);
    return separation * separation <= 1e-10 * normal2;
}

// Compacted records only:
// A.w links triangles of one opaque plane.
// B.z links plane leaders.
// B.w of the cell's first record holds its first plane leader.
// All links are absolute record indices plus one.
void meshBuildPlanes(uint off, uint count) {
    if (count == 0u) return;

    uint firstPlane = 0u;
    for (uint i = 0u; i < count; i++) {
        uint index = off + i;
        uvec4 recordA = terrainTris.ctris[index * 2u];
        uvec4 recordB = terrainTris.ctris[index * 2u + 1u];
        recordA.w = 0u;
        recordB.z = 0u;
        recordB.w = 0u;

        terrainTris.ctris[index * 2u] = recordA;
        terrainTris.ctris[index * 2u + 1u] = recordB;
        if ((recordB.x >> 24) != 0u) continue;

        uvec3 canonical = meshCanonical(recordA);
        vec3 a = terrainUnpack(canonical.x);
        vec3 b = terrainUnpack(canonical.y);
        vec3 d = terrainUnpack(canonical.z);
        vec3 normal = cross(b - a, d - a);
        if (dot(normal, normal) < 1e-12) continue;

        uint leader = firstPlane;
        for (uint guard = 0u; guard < count && leader != 0u; guard++) {
            uint leaderIndex = leader - 1u;
            uvec3 other = meshCanonical(terrainTris.ctris[leaderIndex * 2u]);
            if (meshSamePlane(a, normal, other)) break;
            leader = terrainTris.ctris[leaderIndex * 2u + 1u].z;
        }

        if (leader == 0u) {
            recordB.z = firstPlane;
            terrainTris.ctris[index * 2u + 1u] = recordB;
            firstPlane = index + 1u;
            continue;
        }

        bool duplicate = false;
        uint member = leader;
        for (uint guard = 0u; guard < count && member != 0u; guard++) {
            uvec4 otherA = terrainTris.ctris[(member - 1u) * 2u];
            if (all(equal(canonical, meshCanonical(otherA)))) {
                duplicate = true;
                break;
            }
            member = otherA.w;
        }
        if (duplicate) continue;

        uint leaderIndex = leader - 1u;
        uvec4 leaderA = terrainTris.ctris[leaderIndex * 2u];
        recordA.w = leaderA.w;
        leaderA.w = index + 1u;
        terrainTris.ctris[index * 2u] = recordA;
        terrainTris.ctris[leaderIndex * 2u] = leaderA;
    }

    uvec4 firstB = terrainTris.ctris[off * 2u + 1u];
    firstB.w = firstPlane;
    terrainTris.ctris[off * 2u + 1u] = firstB;
}

#else

float meshCross2(vec2 a, vec2 b) {
    return a.x * b.y - a.y * b.x;
}

// Twice the signed sector area. Positive rescaling preserves the angle.
float meshCircleArc(vec2 a, vec2 b) {
    float scaleA = max(abs(a.x), abs(a.y));
    float scaleB = max(abs(b.x), abs(b.y));
    if (scaleA < 1e-20 || scaleB < 1e-20) return 0.0;
    a /= scaleA;
    b /= scaleB;
    return atan(meshCross2(a, b), dot(a, b));
}

// Edge integral in homogeneous source coordinates, with positive z.
// Circle intersections use the line's normal form to avoid subtracting
// large nearly equal terms when projected endpoints are far away.
float meshCircleEdge(vec3 a, vec3 b) {
    if (dot(a.xy, a.xy) <= a.z * a.z &&
        dot(b.xy, b.xy) <= b.z * b.z) {
        return meshCross2(a.xy / a.z, b.xy / b.z);
    }

    vec3 line = cross(a, b);
    float line2 = dot(line.xy, line.xy);
    if (line2 <= 1e-30) return 0.0;

    float inverseLength = inversesqrt(line2);
    vec2 normal = line.xy * inverseLength;
    float distance = -line.z * inverseLength;
    if (abs(distance) >= 1.0) return meshCircleArc(a.xy, b.xy);

    vec2 tangent = vec2(normal.y, -normal.x);
    float start = dot(a.xy, tangent) / a.z;
    float end = dot(b.xy, tangent) / b.z;
    float halfChord = sqrt(max(1.0 - distance * distance, 0.0));

    float low = max(start, -halfChord);
    float high = min(end, halfChord);
    if (high <= low) return meshCircleArc(a.xy, b.xy);

    vec2 centre = normal * distance;
    vec2 enter = centre + tangent * low;
    vec2 leave = centre + tangent * high;

    float twiceArea = meshCross2(enter, leave);
    if (start < low) twiceArea += meshCircleArc(a.xy, enter);
    if (end > high) twiceArea += meshCircleArc(leave, b.xy);
    return twiceArea;
}

// Triangle coordinates are homogeneous source coordinates:
// xy is lateral displacement divided by cone slope, z is ray distance.
float meshTriangleDiscCoverage(vec3 a, vec3 b, vec3 d, float len) {
    const float nearDepth = 1e-4;
    float lowDepth = min(a.z, min(b.z, d.z));
    float highDepth = max(a.z, max(b.z, d.z));
    if (len <= nearDepth || highDepth < nearDepth || lowDepth > len) {
        return 0.0;
    }

    // Reject triangles outside the square enclosing the source disc.
    vec4 boundsA = vec4(a.x, -a.x, a.y, -a.y) + a.z;
    vec4 boundsB = vec4(b.x, -b.x, b.y, -b.y) + b.z;
    vec4 boundsD = vec4(d.x, -d.x, d.y, -d.y) + d.z;
    if (any(lessThan(max(boundsA, max(boundsB, boundsD)), vec4(0.0)))) {
        return 0.0;
    }

    if (lowDepth >= nearDepth && highDepth <= len) {
        vec3 ab = cross(a, b);
        vec3 bd = cross(b, d);
        vec3 da = cross(d, a);
        float determinant = dot(ab, d);
        if (determinant == 0.0) return 0.0;

        float orientation = determinant < 0.0 ? -1.0 : 1.0;
        vec3 signedGap = vec3(ab.z, bd.z, da.z) * orientation;
        vec3 normal2 = vec3(
            dot(ab.xy, ab.xy), dot(bd.xy, bd.xy), dot(da.xy, da.xy));
        vec3 gap2 = signedGap * signedGap;

        // An edge separates the entire disc from the triangle.
        if ((signedGap.x < 0.0 && gap2.x >= normal2.x) ||
            (signedGap.y < 0.0 && gap2.y >= normal2.y) ||
            (signedGap.z < 0.0 && gap2.z >= normal2.z)) return 0.0;

        // The triangle contains the entire disc.
        if (all(greaterThanEqual(signedGap, vec3(0.0))) &&
            all(greaterThanEqual(gap2, normal2))) return 1.0;

        float twiceArea = meshCircleEdge(a, b) +
            meshCircleEdge(b, d) + meshCircleEdge(d, a);
        return clamp(abs(twiceArea) * 0.159154943092, 0.0, 1.0);
    }

    // Depth clipping preserves portions of the original edges and adds
    // at most one closing edge on each depth plane.
    vec3 nearEnter = vec3(0.0);
    vec3 nearLeave = vec3(0.0);
    vec3 farEnter = vec3(0.0);
    vec3 farLeave = vec3(0.0);
    uint crossings = 0u;
    float twiceArea = 0.0;

    for (int edgeIndex = 0; edgeIndex < 3; edgeIndex++) {
        vec3 edgeA = edgeIndex == 0 ? a : (edgeIndex == 1 ? b : d);
        vec3 edgeB = edgeIndex == 0 ? b : (edgeIndex == 1 ? d : a);
        float dz = edgeB.z - edgeA.z;
        float low = 0.0;
        float high = 1.0;

        if (dz == 0.0) {
            if (edgeA.z < nearDepth || edgeA.z > len) continue;
        } else {
            float nearU = (nearDepth - edgeA.z) / dz;
            float farU = (len - edgeA.z) / dz;

            bool nearA = edgeA.z >= nearDepth;
            bool nearB = edgeB.z >= nearDepth;
            if (nearA != nearB) {
                vec3 point = mix(edgeA, edgeB, nearU);
                point.z = nearDepth;
                if (nearA) {
                    nearLeave = point;
                    crossings |= 2u;
                } else {
                    nearEnter = point;
                    crossings |= 1u;
                }
            }

            bool farA = edgeA.z <= len;
            bool farB = edgeB.z <= len;
            if (farA != farB) {
                vec3 point = mix(edgeA, edgeB, farU);
                point.z = len;
                if (farA) {
                    farLeave = point;
                    crossings |= 8u;
                } else {
                    farEnter = point;
                    crossings |= 4u;
                }
            }

            if (dz > 0.0) {
                low = max(low, nearU);
                high = min(high, farU);
            } else {
                low = max(low, farU);
                high = min(high, nearU);
            }
        }

        if (high > low) {
            vec3 enter = mix(edgeA, edgeB, low);
            vec3 leave = mix(edgeA, edgeB, high);
            enter.z = clamp(enter.z, nearDepth, len);
            leave.z = clamp(leave.z, nearDepth, len);
            twiceArea += meshCircleEdge(enter, leave);
        }
    }

    if ((crossings & 3u) == 3u) {
        twiceArea += meshCircleEdge(nearLeave, nearEnter);
    }
    if ((crossings & 12u) == 12u) {
        twiceArea += meshCircleEdge(farLeave, farEnter);
    }

    return clamp(abs(twiceArea) * 0.159154943092, 0.0, 1.0);
}

float meshOpaqueVisibility(ivec3 c, vec3 ro, vec3 rd, float k) {
    uint range = terrainHead(c);
    uint count = range >> 18;
    if (count == 0u) return 1.0;

    uint off = range & 0x3FFFFu;
    uint leader = terrainTris.ctris[off * 2u + 1u].w;
    if (leader == 0u) return 1.0;

    float slope = max(k, 1e-7);
    float len = LAMP_RADIUS / slope;

    float side = rd.z >= 0.0 ? 1.0 : -1.0;
    float q = -1.0 / (side + rd.z);
    float xy = rd.x * rd.y * q;
    vec3 axisU = vec3(
        1.0 + side * rd.x * rd.x * q, side * xy, -side * rd.x);
    vec3 axisV = vec3(xy, side + rd.y * rd.y * q, -rd.y);
    axisU /= slope;
    axisV /= slope;

    vec3 base = vec3(c) - ro;
    float coverage = 0.0;

    for (uint planeGuard = 0u;
         planeGuard < count && leader != 0u;
         planeGuard++) {
        float planeCoverage = 0.0;
        uint member = leader;

        for (uint guard = 0u; guard < count && member != 0u; guard++) {
#if DEBUG_VIEW == 14
            traceCost++;
#endif
            uvec4 recordA = terrainTris.ctris[(member - 1u) * 2u];
            uvec3 canonical = meshCanonical(recordA);

            vec3 a = base + terrainUnpack(canonical.x);
            vec3 b = base + terrainUnpack(canonical.y);
            vec3 d = base + terrainUnpack(canonical.z);

            vec3 ha = vec3(dot(a, axisU), dot(a, axisV), dot(a, rd));
            vec3 hb = vec3(dot(b, axisU), dot(b, axisV), dot(b, rd));
            vec3 hd = vec3(dot(d, axisU), dot(d, axisV), dot(d, rd));

            planeCoverage += meshTriangleDiscCoverage(ha, hb, hd, len);
            if (planeCoverage >= 1.0) return 0.0;

            member = recordA.w;
        }

        coverage = max(coverage, planeCoverage);
        leader = terrainTris.ctris[(leader - 1u) * 2u + 1u].z;
    }

    return 1.0 - clamp(coverage, 0.0, 1.0);
}

// Opaque silhouettes in adjacent partial cells reached by the cone.
// Alpha filtering remains in the centre cell.
float meshOpaqueNeighbours(
    vec3 a, vec3 rd, float t0, float t1, float k,
    ivec3 cell, uint mask, ivec3 lampCell, float visibility
) {
    if (visibility <= 0.0 || t1 <= t0) return visibility;

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

        visibility = min(visibility, meshOpaqueVisibility(nb, a, rd, k));
        if (visibility <= 0.0) return 0.0;
    }

    return visibility;
}

#endif
#endif