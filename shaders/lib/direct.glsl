#ifndef DIRECT_GLSL
#define DIRECT_GLSL
#include "/lib/settings.glsl"
#include "/lib/voxel.glsl"
#include "/lib/volume.glsl"
#include "/lib/lights.glsl"
#include "/lib/entity_tris.glsl"
#include "/lib/near.glsl"
#include "/lib/guide.glsl"
#define TERRAIN_OCCLUSION_ONLY
#define TERRAIN_HEAD_SAMPLER
#include "/lib/terrain_tris.glsl"

// Direct block light from spatial lamp bins.
// Full cubes use cone visibility; partial meshes use the centre ray.

const ivec3 FACE_DIR[6] = ivec3[6](
    ivec3( 1, 0, 0), ivec3(-1, 0, 0),
    ivec3( 0, 1, 0), ivec3( 0,-1, 0),
    ivec3( 0, 0, 1), ivec3( 0, 0,-1));

int stepFace(int ax, int s) {
    return ax * 2 + (s > 0 ? 0 : 1);
}

int dominantAxis(vec3 d) {
    vec3 a = abs(d);
    return (a.x >= a.y && a.x >= a.z) ? 0 : (a.y >= a.z ? 1 : 2);
}



#include "/lib/mesh_penumbra.glsl"

// Full-cube occupancy with the source cell exempt.
bool coneFullNeighbour(ivec3 c, uint mask, int face, ivec3 lampCell) {
    return nearFull(mask, face) &&
        any(notEqual(c + FACE_DIR[face], lampCell));
}

// Non-dominated air regions in one cell octant. Each vector selects the
// squared face gaps forming its distance. An open face dominates its
// edges, and an open edge dominates its corner. At most three remain.
int coneAirRegions(
    ivec3 c, uint mask, ivec3 face, ivec3 lampCell,
    out vec3 region[3]
) {
    for (int i = 0; i < 3; i++) region[i] = vec3(0.0);
    int count = 0;

    bool fx = coneFullNeighbour(c, mask, face.x, lampCell);
    bool fy = coneFullNeighbour(c, mask, face.y, lampCell);
    bool fz = coneFullNeighbour(c, mask, face.z, lampCell);

    if (!fx) region[count++] = vec3(1.0, 0.0, 0.0);
    if (!fy) region[count++] = vec3(0.0, 1.0, 0.0);
    if (!fz) region[count++] = vec3(0.0, 0.0, 1.0);

    ivec3 cx = c + FACE_DIR[face.x];

    if (fx && (fy || fz)) {
        uint mx = nearMask(cx);
#if DEBUG_VIEW == 14
        traceCost++;
#endif
        if (fy && !coneFullNeighbour(cx, mx, face.y, lampCell)) {
            region[count++] = vec3(1.0, 1.0, 0.0);
        }
        if (fz && !coneFullNeighbour(cx, mx, face.z, lampCell)) {
            region[count++] = vec3(1.0, 0.0, 1.0);
        }
    }

    if (fy && fz) {
        ivec3 cy = c + FACE_DIR[face.y];
        uint my = nearMask(cy);
#if DEBUG_VIEW == 14
        traceCost++;
#endif
        if (!coneFullNeighbour(cy, my, face.z, lampCell)) {
            region[count++] = vec3(0.0, 1.0, 1.0);
        }
    }

    if (count == 0) {
        ivec3 cxy = cx + FACE_DIR[face.y];
        uint mxy = nearMask(cxy);
#if DEBUG_VIEW == 14
        traceCost++;
#endif
        if (!coneFullNeighbour(cxy, mxy, face.z, lampCell)) {
            region[count++] = vec3(1.0);
        }
    }

    return count;
}

// Squared interior distance divided by squared cone radius, capped at one.
float coneDepthAt(
    vec3 gap, vec3 change, float t0, float dt, float k,
    vec3 region[3], int count, float u
) {
    vec3 g = gap + change * u;
    vec3 g2 = g * g;
    float radius = max(k * max(t0 + dt * u, 1e-3), 1e-7);
    float radius2 = radius * radius;
    float depth2 = radius2;

    for (int i = 0; i < count; i++) {
        depth2 = min(depth2, dot(region[i], g2));
    }
    return clamp(depth2 / radius2, 0.0, 1.0);
}

// Parameters where two region distances are equal.
vec2 coneRegionCrossings(vec3 gap, vec3 change, vec3 difference) {
    if (dot(difference, vec3(1.0)) == 0.0) {
        // Face-face and edge-edge comparisons reduce to equal face gaps.
        float slope = dot(difference, change);
        if (abs(slope) < 1e-12) return vec2(-1.0);
        return vec2(-dot(difference, gap) / slope, -1.0);
    }

    // A face against the opposite edge.
    float a = dot(difference, change * change);
    float b = 2.0 * dot(difference, gap * change);
    float c = dot(difference, gap * gap);
    float scale = max(abs(a), max(abs(b), abs(c)));
    if (scale < 1e-20) return vec2(-1.0);

    a /= scale;
    b /= scale;
    c /= scale;

    if (abs(a) < 1e-7) {
        if (abs(b) < 1e-7) return vec2(-1.0);
        return vec2(-c / b, -1.0);
    }

    float discriminant = b * b - 4.0 * a * c;
    if (discriminant < 0.0) return vec2(-1.0);

    float root = sqrt(discriminant);
    float q = -0.5 * (b + (b < 0.0 ? -root : root));
    if (abs(q) < 1e-10) return vec2(-b / (2.0 * a), -1.0);
    return vec2(q / a, c / q);
}

// Each squared normalized distance is convex in inverse ray distance.
// Its lower envelope can reach a maximum only at an endpoint or where
// two regions exchange order. The radius floor adds one breakpoint.
float conePartDepth(
    vec3 gap, vec3 change, float t0, float dt, float k,
    vec3 region[3], int count
) {
    float best = max(
        coneDepthAt(gap, change, t0, dt, k, region, count, 0.0),
        coneDepthAt(gap, change, t0, dt, k, region, count, 1.0));
    if (best >= 1.0) return 1.0;

    float floorTime = max(1e-3, 1e-7 / max(k, 1e-20));
    if (dt > 0.0 && floorTime > t0 && floorTime < t0 + dt) {
        best = max(best, coneDepthAt(
            gap, change, t0, dt, k, region, count,
            (floorTime - t0) / dt));
    }

    for (int i = 0; i < count; i++) {
        for (int j = i + 1; j < count; j++) {
            vec2 roots = coneRegionCrossings(
                gap, change, region[i] - region[j]);

            for (int r = 0; r < 2; r++) {
                float u = roots[r];
                if (u <= 0.0 || u >= 1.0) continue;
                best = max(best, coneDepthAt(
                    gap, change, t0, dt, k, region, count, u));
                if (best >= 1.0) return 1.0;
            }
        }
    }
    return best;
}

// Continuous interior cone coverage. Cell midplanes split the crossing
// into at most four octants. Radius must stay below half a block.
float coneCubeVisibility(
    vec3 a, vec3 rd, float t0, float t1, float k,
    ivec3 c, uint mask, ivec3 lampCell
) {
    vec3 local0 = a - vec3(c) + rd * t0;
    vec3 delta = rd * (t1 - t0);
    vec3 cuts = vec3(1.0);

    for (int axis = 0; axis < 3; axis++) {
        if (abs(delta[axis]) < 1e-8) continue;
        float u = (0.5 - local0[axis]) / delta[axis];
        if (u > 0.0 && u < 1.0) cuts[axis] = u;
    }

    float q = min(cuts.x, cuts.y);
    cuts.y = max(cuts.x, cuts.y);
    cuts.x = q;
    q = min(cuts.y, cuts.z);
    cuts.z = max(cuts.y, cuts.z);
    cuts.y = q;
    q = min(cuts.x, cuts.y);
    cuts.y = max(cuts.x, cuts.y);
    cuts.x = q;

    float depth2 = 0.0;
    float begin = 0.0;

    for (int part = 0; part < 4; part++) {
        float end = part < 3 ? cuts[part] : 1.0;

        if (end > begin) {
            vec3 middle = local0 + delta * (0.5 * (begin + end));
            ivec3 face = ivec3(
                middle.x < 0.5 ? 1 : 0,
                middle.y < 0.5 ? 3 : 2,
                middle.z < 0.5 ? 5 : 4);

            vec3 region[3];
            int count = coneAirRegions(c, mask, face, lampCell, region);
            if (count == 0) return 0.0;

            vec3 reverse = step(vec3(0.5), middle);
            vec3 p0 = clamp(local0 + delta * begin, 0.0, 1.0);
            vec3 p1 = clamp(local0 + delta * end, 0.0, 1.0);
            vec3 gap0 = mix(p0, 1.0 - p0, reverse);
            vec3 gap1 = mix(p1, 1.0 - p1, reverse);

            depth2 = max(depth2, conePartDepth(
                gap0, gap1 - gap0,
                mix(t0, t1, begin), (t1 - t0) * (end - begin),
                k, region, count));
            if (depth2 >= 1.0) return 0.0;
        }

        begin = end;
        if (end >= 1.0) break;
    }

    return 0.5 - 0.5 * sqrt(clamp(depth2, 0.0, 1.0));
}

float passVisibility(
    vec3 a, vec3 rd, float t0, float t1, float k,
    vec3 bmin, vec3 bmax
) {
    float s = 1e3;
    for (int j = 0; j < 3; j++) {
        float t = mix(t0, t1, float(j) * 0.5);
        s = min(s, boxDistance(a + rd * t, bmin, bmax) / (k * max(t, 1e-3)));
    }
    return 0.5 + 0.5 * s;
}

// Squared distance from the origin to a segment.
// Anchor at the nearer endpoint to limit cancellation.
float coneSegmentMin2(vec3 p0, vec3 p1) {
    if (dot(p1, p1) < dot(p0, p0)) {
        vec3 swap = p0;
        p0 = p1;
        p1 = swap;
    }

    vec3 edge = p1 - p0;
    float u = clamp(
        -dot(p0, edge) / max(dot(edge, edge), 1e-30),
        0.0, 1.0);
    vec3 nearest = p0 + edge * u;
    return dot(nearest, nearest);
}

// For an adjacent cube, the nonzero face gaps stay linear throughout
// the current cell crossing. Dividing them by ray distance forms a
// straight segment in inverse-distance space.
float coneDiagonalRatio2(
    vec3 gap0, vec3 gap1, float t0, float t1
) {
    const float timeFloor = 1e-3;

    if (t1 <= timeFloor) {
        return coneSegmentMin2(gap0, gap1) /
            (timeFloor * timeFloor);
    }

    float best = 1e30;
    if (t0 < timeFloor) {
        float u = (timeFloor - t0) / (t1 - t0);
        vec3 gapFloor = mix(gap0, gap1, u);

        best = coneSegmentMin2(gap0, gapFloor) /
            (timeFloor * timeFloor);
        gap0 = gapFloor;
        t0 = timeFloor;
    }

    return min(best, coneSegmentMin2(gap0 / t0, gap1 / t1));
}

// Exterior coverage from edge and corner neighbours.
// The radius is below half a block, so immediate neighbours suffice.
// Geometry is tested before occupancy is loaded.
float coneExteriorDiagonals(
    vec3 a, vec3 rd, float t0, float t1, float k,
    ivec3 cell, ivec3 lampCell, float visibility
) {
    if (visibility <= 0.5 || k <= 0.0) return visibility;

    vec3 localA = a - vec3(cell);
    vec3 p0 = clamp(localA + rd * t0, 0.0, 1.0);
    vec3 p1 = clamp(localA + rd * t1, 0.0, 1.0);

    float ratioLimit = (2.0 * visibility - 1.0) * k;
    float best2 = ratioLimit * ratioLimit;
    float endTime = max(t1, 1e-3);
    float reach = ratioLimit * endTime;
    float endTime2 = endTime * endTime;

    // Only directions whose face gaps can reach the current aperture.
    ivec3 lower = -ivec3(lessThan(min(p0, p1), vec3(reach)));
    ivec3 upper = ivec3(lessThan(
        1.0 - max(p0, p1), vec3(reach)));
    bvec3 axes = greaterThan(upper, lower);
    if (int(axes.x) + int(axes.y) + int(axes.z) < 2) {
        return visibility;
    }

    for (int z = lower.z; z <= upper.z; z++)
    for (int y = lower.y; y <= upper.y; y++)
    for (int x = lower.x; x <= upper.x; x++) {
        if (abs(x) + abs(y) + abs(z) < 2) continue;

        ivec3 nb = cell + ivec3(x, y, z);
        if (!voxelInside(nb) || all(equal(nb, lampCell))) continue;

        vec3 side = vec3(x, y, z);
        vec3 axisMask = abs(side);
        vec3 gap0 = (0.5 + side * (0.5 - p0)) * axisMask;
        vec3 gap1 = (0.5 + side * (0.5 - p1)) * axisMask;

        vec3 lowerGap = min(gap0, gap1);
        if (dot(lowerGap, lowerGap) >= best2 * endTime2) continue;

        float candidate2 = coneDiagonalRatio2(gap0, gap1, t0, t1);
        if (candidate2 >= best2) continue;

        uvec2 nc = nearCell(nb);
#if DEBUG_VIEW == 14
        traceCost++;
#endif
        if (!nearSelfFull(nc.x) || voxelLeaves(nc.y)) continue;

        best2 = candidate2;
        if (best2 <= 0.0) return 0.5;
    }

    return min(visibility, 0.5 + 0.5 * sqrt(best2) / k);
}




float voxelSegmentVisibility(
    vec3 a, vec3 b
) {
    vec3 d = b - a;
    float len = length(d);
    if (len < 1e-4) return 1.0;
    vec3 rd = d / len;
    float k = LAMP_RADIUS / len;

    ivec3 cell = ivec3(floor(a));
    ivec3 endCell = ivec3(floor(b));
    ivec3 stp = ivec3(sign(rd));
    vec3 inv = 1.0 / max(abs(rd), vec3(1e-6));
    vec3 tMax = abs(vec3(cell) + max(vec3(stp), vec3(0.0)) - a) * inv;

    float vis = 1.0;
    float t = 0.0;
    int entryFace = -1;
    for (int i = 0; i < 64 && vis > 0.0; i++) {
        if (all(equal(cell, endCell))) break;
        int ax = tMax.x < tMax.y ? (tMax.x < tMax.z ? 0 : 2) : (tMax.y < tMax.z ? 1 : 2);
        float tExit = tMax[ax];
        bool last = tExit >= len;
        int exitFace = stepFace(ax, stp[ax]);

        uvec2 nc = nearCell(cell);
        uint mask = nc.x;
#if DEBUG_VIEW == 14
        traceCost++;
#endif
        if (nearSelfPartial(mask)) {
            vis = min(vis, partialMeshVisibility(
                cell, nc.y, a, rd, t, min(tExit, len),
                entryFace, last ? -1 : exitFace, k));
            if (vis <= 0.0) return 0.0;
        }

        bool insideCube = i > 0 &&
            nearSelfFull(mask) && !voxelLeaves(nc.y);
        if (insideCube) {
#if !SKIP_CONE_CUBE
            vis = min(vis, coneCubeVisibility(
                a, rd, t, min(tExit, len), k, cell, mask, endCell));
            if (vis <= 0.0) return 0.0;
#endif
        } else if (!last) {
            for (int f = 0; f < 6; f++) {
                if (!nearFull(mask, f)) continue;
                ivec3 nb = cell + FACE_DIR[f];
                if (all(equal(nb, endCell))) continue;
                vis = min(vis, passVisibility(
                    a, rd, t, tExit, k, vec3(nb), vec3(nb) + 1.0));
            }
            if (nearDiagonalCube(mask)) {
                vis = coneExteriorDiagonals(
                    a, rd, t, tExit, k, cell, endCell, vis);
            }
        }

#if !SKIP_RECT
        vis = meshRectNeighbours(
            a, rd, t, min(tExit, len), k, cell, mask, endCell, vis);
        if (vis <= 0.0) return 0.0;
#endif
        if (last) break;

        ivec3 next = cell;
        next[ax] += stp[ax];
        if (!voxelInside(next)) break;
        if (all(equal(next, endCell))) break;







        if (nearLeaves(mask, exitFace) &&
            !leavesPass(a + rd * tExit + vec3(voxelOrigin(cameraPosition)), exitFace ^ 1)) {
            vis = 0.0;
            break;
        }

        cell = next;
        t = tExit;
        entryFace = exitFace ^ 1;
        tMax[ax] += inv[ax];
    }

    return clamp(vis, 0.0, 1.0);
}

// Unshadowed irradiance without source colour.
float lampWeight(vec3 N, vec3 d, float d2, uint v) {
    if (d2 < 1e-6) return 0.0;
    float ndl = dot(N, d) * inversesqrt(d2);
    if (ndl <= 0.0) return 0.0;
    return lampStrength(v) * lampFalloff(d2, ndl);
}

// Ray start in grid index space. On a full block the start is pinned into
// the cell half a block in front of the surface, the one the volume taps
// read: depth reconstruction puts seam pixels slightly below the surface,
// and the pin keeps a shallow ray from stepping sideways through the
// ground. On a partial block the surface lies inside the block's own cell
// and its planes sit on sixteenths, so the position along the normal is
// snapped to the nearest sixteenth and pushed a little in front.
vec3 rayStart(vec3 worldPos, vec3 N, ivec3 origin) {
    vec3 pg = worldPos - vec3(origin);
    ivec3 behind = ivec3(floor(pg - N * 0.5));
    if (voxelPartial(nearCell(behind).y)) {
        int ax = dominantAxis(N);
        pg[ax] = round(pg[ax] * 16.0) / 16.0 + sign(N[ax]) * 0.03;
        return pg;
    }
    ivec3 startCell = ivec3(floor(pg + N * 0.5));
    return clamp(pg + N * 0.05, vec3(startCell) + 0.01, vec3(startCell) + 0.99);
}

// Entity triangle set of the frame and its grid, read once per pixel.
// terrain is false for entity and hand pixels. The captured triangles are
// posed by the shadow pass and relayed up to a quarter second late, so they
// do not line up with the entity the G-buffer drew; testing them against
// its own surface only paints its shadow onto itself.
bool directEntityFrame(int frame, bool terrain, out int eset, out vec3 elo, out vec3 ecs) {
    eset = entityTriSet(frame);
    elo = vec3(0.0);
    ecs = vec3(1.0);
#if SKIP_ENTITY
    return false;
#else
    return terrain && entityGridFrame(eset, elo, ecs);
#endif
}

// Fraction of lamp L seen from the ray start Pg, Pc being the same point
// relative to the camera for the entity triangles
float lampVisibility(vec3 Pg, vec3 Pc, uvec4 L, int eset, bool entities, vec3 elo, vec3 ecs, int frame) {
    vec3 lpg = lampPosition(L);
    vec3 d = lpg - Pg;
    float dist = length(d);
    vec3 rd = d / dist;
    if (entities && traceEntityTrisFrame(eset, elo, ecs, Pc, rd, 0.02, dist) > 0.0) return 0.0;
#if SKIP_WALK
    float vis = 1.0;
#if DEAD_WALK
    // Never taken at run time and kept by the compiler, since the frame
    // comes from a uniform: the walk's registers stay allocated without
    // its loads
    if (frame < 0) vis = voxelSegmentVisibility(Pg, lpg);
#endif
    return vis;
#else
    return voxelSegmentVisibility(Pg, lpg);
#endif
}

vec3 directLight(vec3 worldPos, vec3 N, int frame, bool terrain) {
    int set = lightSet(frame);
    ivec3 origin = voxelOrigin(cameraPosition);
    vec3 Pg = rayStart(worldPos, N, origin);
    vec3 Pc = Pg + vec3(origin) - cameraPosition;

    int eset; vec3 elo, ecs;
    bool entities = directEntityFrame(frame, terrain, eset, elo, ecs);

    float bestW[DIRECT_LAMPS];
    int bestI[DIRECT_LAMPS];
    for (int k = 0; k < DIRECT_LAMPS; k++) { bestW[k] = 0.0; bestI[k] = -1; }

    // Unshadowed light of the lamps that get no ray
    vec3 rest = vec3(0.0);
    int bi = lampBinOf(Pg);
    uint n = lampBinCount(bi);
    for (uint i = 0u; i < n; i++) {
        int li = lampBinLamp(bi, i);
        uvec4 L = lightList.lights[set * LIGHTS_MAX + li];
        vec3 d = lampPosition(L) - Pg;
        float d2 = dot(d, d);
        if (d2 > LPV_RANGE * LPV_RANGE) continue;
        float w = lampWeight(N, d, d2, L.w);
        if (w <= 0.0) continue;
        bool placed = false;
        for (int k = 0; k < DIRECT_LAMPS; k++) {
            if (w > bestW[k]) {
                int last = DIRECT_LAMPS - 1;
                if (bestI[last] >= 0) {
                    uvec4 Lp = lightList.lights[set * LIGHTS_MAX + bestI[last]];
                    rest += emissionColor(voxelColorClass(Lp.w)) * bestW[last];
                }
                for (int j = last; j > k; j--) { bestW[j] = bestW[j - 1]; bestI[j] = bestI[j - 1]; }
                bestW[k] = w;
                bestI[k] = li;
                placed = true;
                break;
            }
        }
        if (!placed) rest += emissionColor(voxelColorClass(L.w)) * w;
    }

    vec3 sum = vec3(0.0);
    float visSum = 0.0;
    int traced = 0;
    for (int k = 0; k < DIRECT_LAMPS; k++) {
        if (bestI[k] < 0) continue;
        uvec4 L = lightList.lights[set * LIGHTS_MAX + bestI[k]];
        vec3 col = emissionColor(voxelColorClass(L.w));
        if (bestW[k] < DIRECT_MINOR * bestW[0]) { rest += col * bestW[k]; continue; }
        float vis = lampVisibility(Pg, Pc, L, eset, entities, elo, ecs, frame);
        visSum += vis;
        traced++;
        sum += col * bestW[k] * vis;
    }
    if (traced > 0) sum += rest * (visSum / float(traced));
    return sum * LPV_EMISSION * DIRECT_STRENGTH;
}

#if DEBUG_VIEW == 10
// Visibility of the strongest lamp alone, no weight and no falloff. Grey is
// the fraction seen through the voxels; blue is blocked by the entity
// triangles; dark blue is no lamp in range or facing away.
vec3 directDebug(vec3 worldPos, vec3 N, int frame) {
    int set = lightSet(frame);
    ivec3 origin = voxelOrigin(cameraPosition);
    vec3 Pg = rayStart(worldPos, N, origin);
    vec3 P = Pg + vec3(origin);

    float bestW = 0.0;
    int bestI = -1;
    int bi = lampBinOf(Pg);
    uint n = lampBinCount(bi);
    for (uint i = 0u; i < n; i++) {
        int li = lampBinLamp(bi, i);
        uvec4 L = lightList.lights[set * LIGHTS_MAX + li];
        vec3 d = lampPosition(L) - Pg;
        float d2 = dot(d, d);
        if (d2 > LPV_RANGE * LPV_RANGE) continue;
        float w = lampWeight(N, d, d2, L.w);
        if (w > bestW) { bestW = w; bestI = li; }
    }
    if (bestI < 0) return vec3(0.0, 0.0, 0.25);

    uvec4 L = lightList.lights[set * LIGHTS_MAX + bestI];
    vec3 lpg = lampPosition(L);
    vec3 d = lpg - Pg;
    float dist = length(d);
    if (entitySegmentBlocked(entityTriSet(frame), P - cameraPosition, d / dist, dist)) return vec3(0.1, 0.1, 1.0);
    return vec3(voxelSegmentVisibility(Pg, lpg));
}
#endif

#if DEBUG_VIEW == 21
// Visibility of the strongest lamp split by estimator: x the rectangle
// coverage of the partial cells crossed and of their neighbours, y the
// centre ray against unpaired opaque and alpha triangles and the full
// faces of partial cells, z the cone against full cubes and leaves.
// Nothing exits early, so every estimator sees the whole segment.
vec3 voxelSegmentVisibilityParts(vec3 a, vec3 b) {
    vec3 parts = vec3(1.0);
    vec3 d = b - a;
    float len = length(d);
    if (len < 1e-4) return parts;
    vec3 rd = d / len;
    float k = LAMP_RADIUS / len;

    ivec3 cell = ivec3(floor(a));
    ivec3 endCell = ivec3(floor(b));
    ivec3 stp = ivec3(sign(rd));
    vec3 inv = 1.0 / max(abs(rd), vec3(1e-6));
    vec3 tMax = abs(vec3(cell) + max(vec3(stp), vec3(0.0)) - a) * inv;

    float t = 0.0;
    int entryFace = -1;
    for (int i = 0; i < 64; i++) {
        if (all(equal(cell, endCell))) break;
        int ax = tMax.x < tMax.y ? (tMax.x < tMax.z ? 0 : 2) : (tMax.y < tMax.z ? 1 : 2);
        float tExit = tMax[ax];
        bool last = tExit >= len;
        int exitFace = stepFace(ax, stp[ax]);
        float tEnd = min(tExit, len);

        uvec2 nc = nearCell(cell);
        uint mask = nc.x;
        if (nearSelfPartial(mask)) {
            uint v = nc.y;
            parts.x = min(parts.x, meshRectCellVisibility(cell, a, rd, k));
            float hard = 1.0;
            if (entryFace >= 0 && voxelFaceFull(v, entryFace)) hard = 0.0;
            if (!last && voxelFaceFull(v, exitFace)) hard = 0.0;
            vec3 lo, hi;
            voxelSpan(v, lo, hi);
            if (raySegmentBox(a, rd, t - 1e-3, tEnd + 1e-3, vec3(cell) + lo, vec3(cell) + hi)) {
                hard = min(hard, meshAlphaVisibility(cell, a, rd, t - 1e-3, tEnd + 1e-3, k));
            }
            parts.y = min(parts.y, hard);
        }

        bool insideCube = i > 0 && nearSelfFull(mask) && !voxelLeaves(nc.y);
        if (insideCube) {
            parts.z = min(parts.z, coneCubeVisibility(a, rd, t, tEnd, k, cell, mask, endCell));
        } else if (!last) {
            float cube = 1.0;
            for (int f = 0; f < 6; f++) {
                if (!nearFull(mask, f)) continue;
                ivec3 nb = cell + FACE_DIR[f];
                if (all(equal(nb, endCell))) continue;
                cube = min(cube, passVisibility(a, rd, t, tExit, k, vec3(nb), vec3(nb) + 1.0));
            }
            if (nearDiagonalCube(mask)) cube = coneExteriorDiagonals(a, rd, t, tExit, k, cell, endCell, cube);
            parts.z = min(parts.z, cube);
        }

        parts.x = min(parts.x, meshRectNeighbours(a, rd, t, tEnd, k, cell, mask, endCell, 1.0));
        if (last) break;

        ivec3 next = cell;
        next[ax] += stp[ax];
        if (!voxelInside(next)) break;
        if (all(equal(next, endCell))) break;
        if (nearLeaves(mask, exitFace) &&
            !leavesPass(a + rd * tExit + vec3(voxelOrigin(cameraPosition)), exitFace ^ 1)) {
            parts.z = 0.0;
            break;
        }

        cell = next;
        t = tExit;
        entryFace = exitFace ^ 1;
        tMax[ax] += inv[ax];
    }
    return clamp(parts, 0.0, 1.0);
}

// On a partial block: the record kinds of its cell after compaction, red
// the rectangle leaders, green the unpaired opaque triangles, blue the
// alpha ones, each over 32. Elsewhere: the three visibilities above for
// the strongest lamp, so a shadow cast by one estimator alone shows in
// the complementary colour. Grey with no lamp in range.
vec3 estimatorDebug(vec3 worldPos, vec3 N, int frame, ivec3 cell) {
    if (voxelInside(cell) && voxelPartial(nearCell(cell).y)) {
        uint range = terrainHead(cell);
        uint count = min(range >> 18, 1024u);
        uint off = range & 0x3FFFFu;
        ivec3 kinds = ivec3(0);
        for (uint i = 0u; i < count; i++) {
            uint w = terrainTris.ctris[(off + i) * 2u].w;
            if (w == 8u) kinds.z++;
            else if (w == 0u) kinds.y++;
            else if (w < 4u) kinds.x++;
        }
        return vec3(kinds) / 32.0;
    }

    int set = lightSet(frame);
    ivec3 origin = voxelOrigin(cameraPosition);
    vec3 Pg = rayStart(worldPos, N, origin);
    float bestW = 0.0;
    int bestI = -1;
    int bi = lampBinOf(Pg);
    uint n = lampBinCount(bi);
    for (uint i = 0u; i < n; i++) {
        int li = lampBinLamp(bi, i);
        uvec4 L = lightList.lights[set * LIGHTS_MAX + li];
        vec3 d = lampPosition(L) - Pg;
        float d2 = dot(d, d);
        if (d2 > LPV_RANGE * LPV_RANGE) continue;
        float w = lampWeight(N, d, d2, L.w);
        if (w > bestW) { bestW = w; bestI = li; }
    }
    if (bestI < 0) return vec3(0.25);
    return voxelSegmentVisibilityParts(Pg, lampPosition(lightList.lights[set * LIGHTS_MAX + bestI]));
}
#endif

#if DEBUG_VIEW == 22
// Rectangle of cell c with the largest coverage so far: the axis of its
// normal and whether a join extended it
void rectDebugCell(ivec3 c, vec3 ro, vec3 rd, float k, inout float best, inout int axis, inout bool joined) {
    uint range = terrainHead(c);
    uint count = range >> 18;
    if (count == 0u) return;
    uint off = range & 0x3FFFFu;
    uint member = terrainTris.ctris[off * 2u + 1u].w;
    vec3 base = vec3(c) - ro;
    for (uint guard = 0u; guard < count && member != 0u; guard++) {
        uint index = member - 1u;
        uvec4 A = terrainTris.ctris[index * 2u];
        uvec4 B = terrainTris.ctris[index * 2u + 1u];
        float cov = meshRectCoverage(A, B.y, base, rd, k);
        if (cov > best) {
            best = cov;
            uint kind = A.w;
            uint originKey = kind == 1u ? A.x : (kind == 2u ? A.y : A.z);
            uint uKey = kind == 1u ? A.y : A.x;
            uint vKey = kind == 3u ? A.y : A.z;
            vec3 corner = terrainUnpack(originKey);
            vec3 n = abs(cross(terrainUnpack(uKey) - corner, terrainUnpack(vKey) - corner));
            axis = (n.x >= n.y && n.x >= n.z) ? 0 : (n.y >= n.z ? 1 : 2);
            joined = B.y != 0u;
        }
        member = B.z;
    }
}

// The neighbour selection of meshRectNeighbours, feeding rectDebugCell
void rectDebugNeighbours(
    vec3 a, vec3 rd, float t0, float t1, float k,
    ivec3 cell, uint mask, ivec3 lampCell,
    inout float best, inout int axis, inout bool joined
) {
    if (t1 <= t0) return;
    float radius = k * t1;
    vec3 localA = a - vec3(cell);
    vec3 p0 = clamp(localA + rd * t0, 0.0, 1.0);
    vec3 p1 = clamp(localA + rd * t1, 0.0, 1.0);
    ivec3 lower = -ivec3(lessThan(min(p0, p1), vec3(radius)));
    ivec3 upper = ivec3(lessThan(1.0 - max(p0, p1), vec3(radius)));

    for (int z = lower.z; z <= upper.z; z++)
    for (int y = lower.y; y <= upper.y; y++)
    for (int x = lower.x; x <= upper.x; x++) {
        int directions = abs(x) + abs(y) + abs(z);
        if (directions == 0) continue;
        ivec3 offset = ivec3(x, y, z);
        ivec3 nb = cell + offset;
        if (!voxelInside(nb) || all(equal(nb, lampCell))) continue;
        if (directions == 1) {
            int ax = x != 0 ? 0 : (y != 0 ? 1 : 2);
            int face = ax * 2 + (offset[ax] > 0 ? 0 : 1);
            if (!nearPartial(mask, face)) continue;
        }
        vec3 side = vec3(offset);
        vec3 axisMask = abs(side);
        vec3 gap0 = (0.5 + side * (0.5 - p0)) * axisMask;
        vec3 gap1 = (0.5 + side * (0.5 - p1)) * axisMask;
        vec3 gap = min(gap0, gap1);
        if (dot(gap, gap) >= radius * radius) continue;
        uvec2 nc = nearCell(nb);
        if (!nearSelfPartial(nc.x)) continue;
        vec3 lo, hi;
        voxelSpan(nc.y, lo, hi);
        if (!raySegmentBox(a, rd, t0, t1, vec3(nb) + lo - radius, vec3(nb) + hi + radius)) continue;
        rectDebugCell(nb, a, rd, k, best, axis, joined);
    }
}

// Colour of the rectangle with the largest coverage along the segment to
// the strongest lamp: red a normal along X, green Y, blue Z, pastel when
// joined, brightness the coverage. Grey on a partial block, dark where no
// rectangle covers anything, grey 0.25 with no lamp in range.
vec3 rectDebug(vec3 worldPos, vec3 N, int frame, ivec3 pixel) {
    if (voxelInside(pixel) && voxelPartial(nearCell(pixel).y)) return vec3(0.3);

    int set = lightSet(frame);
    ivec3 origin = voxelOrigin(cameraPosition);
    vec3 Pg = rayStart(worldPos, N, origin);
    float bestW = 0.0;
    int bestI = -1;
    int bi = lampBinOf(Pg);
    uint n = lampBinCount(bi);
    for (uint i = 0u; i < n; i++) {
        int li = lampBinLamp(bi, i);
        uvec4 L = lightList.lights[set * LIGHTS_MAX + li];
        vec3 d = lampPosition(L) - Pg;
        float d2 = dot(d, d);
        if (d2 > LPV_RANGE * LPV_RANGE) continue;
        float w = lampWeight(N, d, d2, L.w);
        if (w > bestW) { bestW = w; bestI = li; }
    }
    if (bestI < 0) return vec3(0.25);
    vec3 b = lampPosition(lightList.lights[set * LIGHTS_MAX + bestI]);

    vec3 a = Pg;
    vec3 d = b - a;
    float len = length(d);
    if (len < 1e-4) return vec3(0.08);
    vec3 rd = d / len;
    float k = LAMP_RADIUS / len;

    ivec3 cell = ivec3(floor(a));
    ivec3 endCell = ivec3(floor(b));
    ivec3 stp = ivec3(sign(rd));
    vec3 inv = 1.0 / max(abs(rd), vec3(1e-6));
    vec3 tMax = abs(vec3(cell) + max(vec3(stp), vec3(0.0)) - a) * inv;

    float best = 0.0;
    int axis = -1;
    bool joined = false;
    float t = 0.0;
    for (int i = 0; i < 64; i++) {
        if (all(equal(cell, endCell))) break;
        int ax = tMax.x < tMax.y ? (tMax.x < tMax.z ? 0 : 2) : (tMax.y < tMax.z ? 1 : 2);
        float tExit = tMax[ax];
        bool last = tExit >= len;
        float tEnd = min(tExit, len);
        uvec2 nc = nearCell(cell);
        if (nearSelfPartial(nc.x)) rectDebugCell(cell, a, rd, k, best, axis, joined);
        rectDebugNeighbours(a, rd, t, tEnd, k, cell, nc.x, endCell, best, axis, joined);
        if (last) break;
        ivec3 next = cell;
        next[ax] += stp[ax];
        if (!voxelInside(next) || all(equal(next, endCell))) break;
        cell = next;
        t = tExit;
        tMax[ax] += inv[ax];
    }

    if (axis < 0 || best <= 0.0) return vec3(0.08);
    vec3 hue = axis == 0 ? vec3(1.0, 0.15, 0.15) : (axis == 1 ? vec3(0.15, 1.0, 0.15) : vec3(0.15, 0.15, 1.0));
    if (joined) hue = mix(hue, vec3(1.0), 0.5);
    return hue * (0.15 + 0.85 * clamp(best, 0.0, 1.0));
}
#endif

#if DEBUG_VIEW == 23
// Whether the straight line from a to b passes the grid: a full cube
// entered, a leaves face failing its dither or an opaque triangle of a
// partial block blocks it. The cells of b and of the lamp are exempt,
// like the lamp cell in the cone trace.
bool hardRayClear(vec3 a, vec3 b, ivec3 lampCell) {
    vec3 d = b - a;
    float len = length(d);
    if (len < 1e-4) return true;
    vec3 rd = d / len;
    ivec3 cell = ivec3(floor(a));
    ivec3 endCell = ivec3(floor(b));
    ivec3 stp = ivec3(sign(rd));
    vec3 inv = 1.0 / max(abs(rd), vec3(1e-6));
    vec3 tMax = abs(vec3(cell) + max(vec3(stp), vec3(0.0)) - a) * inv;
    float t = 0.0;
    for (int i = 0; i < 96; i++) {
        if (all(equal(cell, endCell)) || all(equal(cell, lampCell))) return true;
        int ax = tMax.x < tMax.y ? (tMax.x < tMax.z ? 0 : 2) : (tMax.y < tMax.z ? 1 : 2);
        float tExit = tMax[ax];
        float tEnd = min(tExit, len);
        int exitFace = stepFace(ax, stp[ax]);
        uvec2 nc = nearCell(cell);
        if (i > 0 && nearSelfFull(nc.x) && !voxelLeaves(nc.y)) return false;
        if (nearSelfPartial(nc.x)) {
            vec3 n;
            if (traceTerrainCell(cell, a, rd, t - 1e-3, tEnd + 1e-3, n) > 0.0) return false;
        }
        if (tExit >= len) return true;
        ivec3 next = cell;
        next[ax] += stp[ax];
        if (!voxelInside(next)) return true;
        if (nearLeaves(nc.x, exitFace) &&
            !leavesPass(a + rd * tExit + vec3(voxelOrigin(cameraPosition)), exitFace ^ 1)) return false;
        cell = next;
        t = tExit;
        tMax[ax] += inv[ax];
    }
    return true;
}

// Share of a disc of LAMP_RADIUS around the lamp, facing the receiver,
// that hard rays from a reach
const int REF_RAYS = 32;
float referenceVisibility(vec3 a, vec3 lamp) {
    vec3 rd = normalize(lamp - a);
    vec3 t1 = normalize(cross(rd, abs(rd.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
    vec3 t2 = cross(rd, t1);
    ivec3 lampCell = ivec3(floor(lamp));
    float seen = 0.0;
    for (int i = 0; i < REF_RAYS; i++) {
        float r = sqrt((float(i) + 0.5) / float(REF_RAYS));
        float ph = float(i) * 2.39996322973;
        vec3 p = lamp + (t1 * cos(ph) + t2 * sin(ph)) * (r * LAMP_RADIUS);
        if (hardRayClear(a, p, lampCell)) seen += 1.0;
    }
    return seen / float(REF_RAYS);
}

// The reference as grey, tinted red where the analytic estimate lies
// below it and green where above; grey 0.25 with no lamp in range
vec3 referenceDebug(vec3 worldPos, vec3 N, int frame) {
    int set = lightSet(frame);
    ivec3 origin = voxelOrigin(cameraPosition);
    vec3 Pg = rayStart(worldPos, N, origin);
    float bestW = 0.0;
    int bestI = -1;
    int bi = lampBinOf(Pg);
    uint n = lampBinCount(bi);
    for (uint i = 0u; i < n; i++) {
        int li = lampBinLamp(bi, i);
        uvec4 L = lightList.lights[set * LIGHTS_MAX + li];
        vec3 d = lampPosition(L) - Pg;
        float d2 = dot(d, d);
        if (d2 > LPV_RANGE * LPV_RANGE) continue;
        float w = lampWeight(N, d, d2, L.w);
        if (w > bestW) { bestW = w; bestI = li; }
    }
    if (bestI < 0) return vec3(0.25);
    vec3 lp = lampPosition(lightList.lights[set * LIGHTS_MAX + bestI]);

    float approx = voxelSegmentVisibility(Pg, lp);
    float ref = referenceVisibility(Pg, lp);
    float diff = approx - ref;
    vec3 c = vec3(ref);
    if (diff < -0.05) c = mix(c, vec3(1.0, 0.0, 0.0), min(-diff * 2.0, 1.0));
    else if (diff > 0.05) c = mix(c, vec3(0.0, 1.0, 0.0), min(diff * 2.0, 1.0));
    return c;
}
#endif

#if DEBUG_VIEW == 17
// Density with which the strongest lamp of the pixel's bin shoots towards
// the pixel, relative to uniform: dark green at 1, red above, blue below,
// purple for a lamp without a tree, grey with no lamp in range
vec3 guideDebug(vec3 worldPos, vec3 N, int frame) {
    int set = lightSet(frame);
    ivec3 origin = voxelOrigin(cameraPosition);
    vec3 Pg = rayStart(worldPos, N, origin);

    float bestW = 0.0;
    int bestI = -1;
    int bi = lampBinOf(Pg);
    uint n = lampBinCount(bi);
    for (uint i = 0u; i < n; i++) {
        int li = lampBinLamp(bi, i);
        uvec4 L = lightList.lights[set * LIGHTS_MAX + li];
        vec3 d = lampPosition(L) - Pg;
        float d2 = dot(d, d);
        if (d2 > LPV_RANGE * LPV_RANGE) continue;
        float w = lampWeight(N, d, d2, L.w);
        if (w > bestW) { bestW = w; bestI = li; }
    }
    if (bestI < 0) return vec3(0.1);
    uint slot = lightList.guideSlot[set * LIGHTS_MAX + bestI];
    if (slot == GUIDE_NONE) return vec3(0.3, 0.0, 0.3);
    vec3 dir = normalize(Pg - lampPosition(lightList.lights[set * LIGHTS_MAX + bestI]));
    float pdf = guidePdfDir(int(slot), guideTreeSet(frame), dir);
    float l = clamp(log2(max(pdf, 1e-4)) / 3.0, -1.0, 1.0);
    vec3 mid = vec3(0.0, 0.3, 0.0);
    return l < 0.0 ? mix(mid, vec3(0.0, 0.0, 1.0), -l) : mix(mid, vec3(1.0, 0.0, 0.0), l);
}
#endif

#endif
