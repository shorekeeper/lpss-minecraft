#version 430
#include "/lib/settings.glsl"
#include "/lib/voxel.glsl"
#include "/lib/bounce.glsl"
#include "/lib/fogvol.glsl"
#include "/lib/history.glsl"
#include "/lib/lights.glsl"

// Folds this frame's fog deposits into the persistent fog volumes. Two
// pairs alternate by frame parity: last frame's is read, shifted by the
// camera's block-level movement, and the other is written for the
// composite pass to sample, with the confidence weight of lib/history.glsl
// and this frame's reset flags. The flow is the luminance-weighted mean
// direction of the light and is blended with the same weight as the
// colour, so their ratio stays the anisotropy. The counters are zeroed for
// the next frame.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
const ivec3 workGroups = ivec3(16, 16, 16);

layout(rgba16f) uniform image3D fogImgA;
layout(rgba16f) uniform image3D fogImgB;
layout(rgba16f) uniform image3D fogDirImgA;
layout(rgba16f) uniform image3D fogDirImgB;
layout(r8ui)    uniform readonly uimage3D resetImgA;
layout(r8ui)    uniform readonly uimage3D resetImgB;

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform int frameCounter;

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

void main() {
#if SKIP_COMPUTE
    return;
#endif
    ivec3 idx = ivec3(gl_GlobalInvocationID);
    if (!voxelInside(idx)) return;

    // shadowcomp_c has compared this frame's lamps with the other set; it
    // is free for the next frame
    if (all(equal(idx, ivec3(0)))) lightsClear(1 - lightSet(frameCounter));

    int b = fogIndex(idx);
    vec3 cur = bounceDecode(uvec3(fogAcc.v[b], fogAcc.v[b + 1], fogAcc.v[b + 2]));
    vec3 flow = vec3(ivec3(fogAcc.v[b + 3], fogAcc.v[b + 4], fogAcc.v[b + 5])) / BOUNCE_FIXED;
    for (int k = 0; k < 6; k++) fogAcc.v[b + k] = 0u;
    // The buffer starts with whatever was in memory; the cap keeps that
    // from flashing through the first frames, and the flow never exceeds
    // the luminance it was weighted by
    cur = min(cur, vec3(64.0));
    float lum = dot(cur, LUMA);
    float fl = length(flow);
    if (fl > lum) flow *= lum / max(fl, 1e-9);

    ivec3 s = idx + ivec3(floor(cameraPosition)) - ivec3(floor(previousCameraPosition));
    bool even = (frameCounter & 1) == 0;
    vec4 prev = vec4(0.0);
    vec3 prevFlow = vec3(0.0);
    if (voxelInside(s)) {
        prev = even ? imageLoad(fogImgB, s) : imageLoad(fogImgA, s);
        prevFlow = even ? imageLoad(fogDirImgB, s).rgb : imageLoad(fogDirImgA, s).rgb;
        if (any(isnan(prevFlow)) || any(isinf(prevFlow))) prevFlow = vec3(0.0);
    }
    bool reset = (even ? imageLoad(resetImgA, idx).r : imageLoad(resetImgB, idx).r) != 0u;
    float n = reset ? 0.0 : historyCount(prev.a);
    float w = historyWeight(n, FOG_TEMPORAL);

    vec4 o = vec4(mix(prev.rgb, cur, w), n + 1.0);
    vec4 of = vec4(mix(prevFlow, flow, w), 0.0);
    if (even) {
        imageStore(fogImgA, idx, o);
        imageStore(fogDirImgA, idx, of);
    } else {
        imageStore(fogImgB, idx, o);
        imageStore(fogDirImgB, idx, of);
    }
}