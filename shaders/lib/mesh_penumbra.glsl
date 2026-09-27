#ifndef MESH_PENUMBRA_GLSL
#define MESH_PENUMBRA_GLSL
#include "/lib/terrain_tris.glsl"

#include "/lib/mesh_rect.glsl"

uint meshBitCount16(
    uint bits
) {
    bits &= 0xFFFFu;
    bits -= (bits >> 1) & 0x5555u;
    bits = (bits & 0x3333u) + ((bits >> 2) & 0x3333u);
    bits = (bits + (bits >> 4)) & 0x0F0Fu;
    return (bits + (bits >> 8)) & 31u;
}

// Exact rectangular integral of the binary 16x16 mask, including
// fractional boundary texels. The area outside the mask is transparent.
float meshMaskCoverage(uint slot, vec2 uv, vec2 halfExtent) {
    vec2 centre = uv * 16.0;
    vec2 halfSize = max(halfExtent * 16.0, vec2(1e-4));
    vec2 low = clamp(centre - halfSize, 0.0, 16.0);
    vec2 high = clamp(centre + halfSize, 0.0, 16.0);
    if (any(lessThanEqual(high, low))) return 0.0;

    int left = clamp(int(floor(low.x)), 0, 15);
    int right = clamp(int(ceil(high.x)) - 1, 0, 15);
    int bottom = clamp(int(floor(low.y)), 0, 15);
    int top = clamp(int(ceil(high.y)) - 1, 0, 15);

    uint middleBits = 0u;
    if (right > left + 1) {
        middleBits = ((1u << uint(right)) - 1u) &
            ~((1u << uint(left + 1)) - 1u);
    }

    float sum = 0.0;
    for (int row = bottom; row <= top; row++) {
        uint rowBits = terrainTris.mask[int(slot) * 8 + (row >> 1)];
        rowBits = (rowBits >> uint((row & 1) * 16)) & 0xFFFFu;

        float width;
        if (left == right) {
            width = (high.x - low.x) *
                float((rowBits >> uint(left)) & 1u);
        } else {
            width = float(meshBitCount16(rowBits & middleBits));
            width += (float(left + 1) - low.x) *
                float((rowBits >> uint(left)) & 1u);
            width += (high.x - float(right)) *
                float((rowBits >> uint(right)) & 1u);
        }

        float height = min(high.y, float(row + 1)) -
            max(low.y, float(row));
        sum += width * height;
    }

    float area = 4.0 * halfSize.x * halfSize.y;
    return clamp(sum / area, 0.0, 1.0);
}

// UV gradients of the oblique cone footprint on the triangle plane.
// The rectangular filter matches the projected disc's axial variances.
vec2 meshMaskHalfExtent(
    vec3 e1, vec3 e2, vec3 rd,
    vec2 uv1, vec2 uv2, float radius
) {
    vec3 plane = cross(e1, e2);
    float plane2 = dot(plane, plane);
    vec3 gradB = cross(e2, plane) / plane2;
    vec3 gradD = cross(plane, e1) / plane2;

    vec3 gradU = gradB * uv1.x + gradD * uv2.x;
    vec3 gradV = gradB * uv1.y + gradD * uv2.y;
    float inverseFacing = 1.0 / dot(plane, rd);

    gradU -= plane * (dot(gradU, rd) * inverseFacing);
    gradV -= plane * (dot(gradV, rd) * inverseFacing);

    return radius * 0.866025404 *
        vec2(length(gradU), length(gradV));
}

// Alpha coverage at centre-ray intersections. Repeated surfaces take
// the strongest coverage rather than multiplying the same mask.
float meshAlphaVisibility(
    ivec3 c, vec3 ro, vec3 rd, float tmin, float tmax, float k
) {
    uint range = terrainHead(c);
    uint count = range >> 18;
    if (count == 0u) return 1.0;

    uint off = range & 0x3FFFFu;
    vec3 base = vec3(c);
    float visibility = 1.0;

    for (uint i = 0u; i < count; i += 4u) {
        uvec4 A[4];
        for (uint j = 0u; j < 4u; j++) {
            A[j] = terrainTris.ctris[
                (off + min(i + j, count - 1u)) * 2u];
        }

        for (uint j = 0u; j < 4u; j++) {
            if (i + j >= count) break;
            if ((A[j].w & 7u) != 0u) continue;
#if DEBUG_VIEW == 14
            traceCost++;
#endif
            vec3 a = base + terrainUnpack(A[j].x);
            vec3 b = base + terrainUnpack(A[j].y);
            vec3 d = base + terrainUnpack(A[j].z);
            vec2 bary;
            float t = rayTriangle(ro, rd, a, b, d, bary);
            if (!(t > max(tmin, 0.0) && t < tmax)) continue;

            uvec4 B = terrainTris.ctris[(off + i + j) * 2u + 1u];

            // Compaction removes masks that are completely opaque.
            if ((B.x >> 24) == 0u) return 0.0;

            vec2 la = vec2(
                float(A[j].x >> 24), float(B.x & 0xFFu)) / 255.0;
            vec2 lb = vec2(
                float(A[j].y >> 24), float((B.x >> 8) & 0xFFu)) / 255.0;
            vec2 ld = vec2(
                float(A[j].z >> 24), float((B.x >> 16) & 0xFFu)) / 255.0;
            vec2 uv = la + bary.x * (lb - la) + bary.y * (ld - la);

            vec2 halfExtent = meshMaskHalfExtent(
                b - a, d - a, rd, lb - la, ld - la, k * t);
            float coverage = meshMaskCoverage(B.y, uv, halfExtent);

            visibility = min(visibility, 1.0 - coverage);
            if (visibility <= 0.0) return 0.0;
        }
    }

    return visibility;
}

// Rectangle and alpha coverage share the source cone.
// Full boundary faces and unpaired opaque triangles use hard occlusion.
float partialMeshVisibility(
    ivec3 c, uint v, vec3 a, vec3 rd,
    float t0, float t1, int entryFace, int exitFace, float k
) {
    if (entryFace >= 0 && voxelFaceFull(v, entryFace)) return 0.0;
    if (exitFace >= 0 && voxelFaceFull(v, exitFace)) return 0.0;

#if SKIP_RECT
    float visibility = 1.0;
#else
    float visibility = meshRectCellVisibility(c, a, rd, k);
    if (visibility <= 0.0) return 0.0;
#endif

#if SKIP_ALPHA
    return visibility;
#else
    vec3 lo, hi;
    voxelSpan(v, lo, hi);
    if (!raySegmentBox(
        a, rd, t0 - 1e-3, t1 + 1e-3,
        vec3(c) + lo, vec3(c) + hi)) return visibility;

    return min(visibility,
        meshAlphaVisibility(c, a, rd, t0 - 1e-3, t1 + 1e-3, k));
#endif
}

#endif