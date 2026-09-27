#ifndef VOLUME_GLSL
#define VOLUME_GLSL
#include "/lib/voxel.glsl"

#include "/lib/skyvol.glsl"

// Reading the grid, the bounce volume and the sky volume in fragment stages.

uniform usampler3D voxelSampler;
uniform sampler3D bounceSampler;
uniform vec3 cameraPosition;

// 1 well inside the grid, 0 at its edge; the lightmap takes over outside
float gridCoverage(vec3 worldPos) {
    vec3 d = abs(worldPos - vec3(voxelOrigin(cameraPosition)) - float(VOXEL_HALF));
    float m = max(d.x, max(d.y, d.z));
    return 1.0 - smoothstep(float(VOXEL_HALF) - 12.0, float(VOXEL_HALF) - 2.0, m);
}

ivec3 volumeCorner(int k) { return ivec3(k & 1, (k >> 1) & 1, (k >> 2) & 1); }

// Trilinear taps half a block in front of the surface: the base corner and
// eight weights, with corners in cells a block fills dropped and the rest
// renormalised, so a face does not go dark just because the wall behind it
// holds no light. A partial block that leaves its cell's centre open is
// read like air.
void volumeTaps(vec3 worldPos, vec3 N, out ivec3 base, out float w[8]) {
    vec3 p = worldPos + N * 0.5 - vec3(voxelOrigin(cameraPosition)) - 0.5;
    base = ivec3(floor(p));
    vec3 f = p - vec3(base);
    float wsum = 0.0;
    for (int k = 0; k < 8; k++) {
        w[k] = 0.0;
        ivec3 c = volumeCorner(k);
        ivec3 i = base + c;
        if (!voxelInside(i)) continue;
        vec3 w3 = mix(1.0 - f, f, vec3(c));
        float ww = w3.x * w3.y * w3.z;
        if (ww < 1e-4) continue;
        if (voxelFillsCentre(texelFetch(voxelSampler, i, 0).r)) continue;
        w[k] = ww;
        wsum += ww;
    }
    if (wsum > 1e-4) for (int k = 0; k < 8; k++) w[k] /= wsum;
}

// Bounced irradiance, same units as the direct term
vec3 sampleBounce(ivec3 base, float w[8]) {
    vec3 sum = vec3(0.0);
    for (int k = 0; k < 8; k++) {
        if (w[k] <= 0.0) continue;
        sum += texelFetch(bounceSampler, base + volumeCorner(k), 0).rgb * w[k];
    }
    return sum * LPV_EMISSION;
}

vec3 sampleBounce(vec3 worldPos, vec3 N) {
    ivec3 base; float w[8];
    volumeTaps(worldPos, N, base, w);
    return sampleBounce(base, w);
}

// Sky visibility of a surface with normal N from the grid, 1 in the open,
// or -1 when every tap lies in a filled cell. The volume holds the linear
// moments of the cosine-weighted rays a cell sees the sky through, see
// shadowcomp_e.csh: rgb the mean visible direction, a the visible share.
// The clamped cosine of N is taken to first order, 1/4 + (N . d) / 2, and
// the result is divided by the same estimate for an open sky, whose mean
// direction is 2/3 up. A downward normal keeps only its lateral part, so
// an underside reads the cell's share of the sky rather than a negative.
float sampleSky(ivec3 base, float w[8], vec3 N, int frame) {
    vec4 s = vec4(0.0);
    float wsum = 0.0;
    int set = skySet(frame);
    for (int k = 0; k < 8; k++) {
        if (w[k] <= 0.0) continue;
        s += skyMoments(set, base + volumeCorner(k)) * w[k];
        wsum += w[k];
    }
    if (wsum < 1e-4) return -1.0;
    vec3 Nc = vec3(N.x, max(N.y, 0.0), N.z);
    float f = (0.25 * s.a + 0.5 * dot(s.rgb, Nc)) / (0.25 + Nc.y / 3.0);
    return clamp(f, 0.0, 1.0);
}

// Rays the sky cells under the taps have accumulated, as a share of
// SKY_HISTORY
float sampleSkyCount(ivec3 base, float w[8], int frame) {
    float s = 0.0;
    float wsum = 0.0;
    int set = skySet(frame);
    for (int k = 0; k < 8; k++) {
        if (w[k] <= 0.0) continue;
        s += float(min(skyCount(set, base + volumeCorner(k)), uint(SKY_HISTORY))) * w[k];
        wsum += w[k];
    }
    return wsum < 1e-4 ? 0.0 : s / (wsum * float(SKY_HISTORY));
}

#endif

