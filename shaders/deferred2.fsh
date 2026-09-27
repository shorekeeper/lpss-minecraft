#version 330 compatibility
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/material.glsl"
#include "/lib/lighting.glsl"
#include "/lib/volume.glsl"
#include "/lib/entity_tris.glsl"
#include "/lib/direct.glsl"

// Deferred shading. Buffer formats are read by the loader from the raw text,
// so they stay inside a block comment.
/*
const int colortex0Format = RGBA16F; // sRGB albedo in, HDR linear scene colour out
const int colortex1Format = RGB16;   // world normal
const int colortex2Format = RGBA16;  // lightmap.xy, material id
const int colortex6Format = RGBA8;   // grid cell of the block, terrain only
*/

uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D colortex3;
uniform sampler3D voxelColorSampler;
uniform sampler2D colortex6;
uniform sampler2D depthtex0;
uniform sampler2D depthtex2;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform float sunAngle;
uniform float wetness;
uniform int frameCounter;

in vec2 texcoord;


// Grid cell of the block a pixel belongs to: the G-buffer's for terrain,
// the cell behind the surface for anything else
ivec3 pixelCell(vec3 worldPos, vec3 N) {
    vec4 c = texture(colortex6, texcoord);
    if (c.a > 0.5) return ivec3(c.rgb * 255.0 + 0.5);
    return ivec3(floor(worldPos - N * 0.5)) - voxelOrigin(cameraPosition);
}

#if DEBUG_VIEW == 6
// Captured entity triangles: the view ray is traced against them and a hit
// in front of the visible surface is painted green, a hit on the surface
// itself cyan. Cyan over terrain means terrain triangles are in the set.
vec3 debugEntityTris(float depth, vec3 viewPos, vec3 viewDirW, float day) {
    int set = entityTriSet(frameCounter);
    vec3 base = depth >= 1.0
        ? overcastSky(viewDirW, day)
        : srgbToLinear(texture(colortex0, texcoord).rgb) * 0.5;
    float tSurf = depth >= 1.0 ? 1e4 : length(viewPos);
    vec3 eye = (gbufferModelViewInverse * vec4(0.0, 0.0, 0.0, 1.0)).xyz;

    float tHit = traceEntityTris(set, eye, viewDirW, 0.05, tSurf + 0.1);
    if (tHit > 0.0) {
        vec3 c = tHit < tSurf - 0.15 ? vec3(0.1, 1.0, 0.1) : vec3(0.1, 0.8, 1.0);
        base = mix(base, c, 0.75);
    }
    return base;
}
#endif

#if DEBUG_VIEW == 13
// The grid as the traces see it: the view ray is walked cell by cell up to
// the visible surface and the first cell an occluder or emitter holds is
// painted. Air all the way then shows the cell behind the surface: a full
// cube leaves the scene dimmed, anything else is painted by kind, and a
// surface with no voxel behind it at all is dark blue.
vec3 debugVoxelMarch(float depth, vec3 viewPos, vec3 viewDirW) {
    vec3 base = depth >= 1.0 ? vec3(0.02) : srgbToLinear(texture(colortex0, texcoord).rgb) * 0.25;
    float tSurf = depth >= 1.0 ? 64.0 : length(viewPos) - 0.05;
    ivec3 origin = voxelOrigin(cameraPosition);
    vec3 p = (gbufferModelViewInverse * vec4(0.0, 0.0, 0.0, 1.0)).xyz + cameraPosition - vec3(origin);
    ivec3 cell = ivec3(floor(p));
    ivec3 stp = ivec3(sign(viewDirW));
    vec3 inv = 1.0 / max(abs(viewDirW), vec3(1e-6));
    vec3 tMax = abs(vec3(cell) + max(vec3(stp), vec3(0.0)) - p) * inv;
    for (int i = 0; i < 192; i++) {
        if (voxelInside(cell)) {
            uint v = texelFetch(voxelSampler, cell, 0).r;
            if (voxelEmission(v) > 0) return emissionColor(voxelColorClass(v));
            if (voxelEntity(v)) return nearSelfFull(nearMask(cell)) ? vec3(0.7, 0.2, 0.8) : vec3(1.0, 0.1, 0.1);
            if (voxelLeaves(v)) return vec3(0.2, 0.8, 0.2);
            if (voxelFull(v)) return vec3(1.0);
            if (voxelOccluder(v)) return vec3(0.6);
        }
        int ax = tMax.x < tMax.y ? (tMax.x < tMax.z ? 0 : 2) : (tMax.y < tMax.z ? 1 : 2);
        if (tMax[ax] > tSurf) break;
        cell[ax] += stp[ax];
        tMax[ax] += inv[ax];
    }
    if (depth >= 1.0) return base;

    vec3 worldPos = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz + cameraPosition;
    vec3 Nraw = texture(colortex1, texcoord).rgb * 2.0 - 1.0;
    vec3 N = dot(Nraw, Nraw) > 1e-6 ? normalize(Nraw) : vec3(0.0, 1.0, 0.0);
    ivec3 behind = ivec3(floor(worldPos - N * 0.5)) - origin;
    if (!voxelInside(behind)) return base;
    uint v = texelFetch(voxelSampler, behind, 0).r;
    if (voxelEmission(v) > 0) return emissionColor(voxelColorClass(v));
    if (voxelEntity(v)) return nearSelfFull(nearMask(behind)) ? vec3(0.7, 0.2, 0.8) : vec3(1.0, 0.1, 0.1);
    if (voxelLeaves(v)) return vec3(0.2, 0.8, 0.2);
    if (voxelFull(v)) return base;
    if (voxelOccluder(v)) return vec3(0.6);
    return vec3(0.0, 0.0, 0.4);
}
#endif

/* DRAWBUFFERS:0 */
void main() {
    float depth = texture(depthtex0, texcoord).r;
    float day = daylight(sunAngle);

    vec3 viewPos = screenToView(vec3(texcoord, depth), gbufferProjectionInverse);
    vec3 viewDirW = normalize(mat3(gbufferModelViewInverse) * viewPos);

#if DEBUG_VIEW == 6
    gl_FragData[0] = vec4(debugEntityTris(depth, viewPos, viewDirW, day), 1.0);
    return;
#elif DEBUG_VIEW == 13
    gl_FragData[0] = vec4(debugVoxelMarch(depth, viewPos, viewDirW), 1.0);
    return;
#endif

    if (depth >= 1.0) {
        gl_FragData[0] = vec4(overcastSky(viewDirW, day), 1.0);
        return;
    }

    // The hand sits in depthtex0 but not in depthtex2; it is not weathered
    bool hand = abs(texture(depthtex2, texcoord).r - depth) > 1e-7;

    vec3 albedo = srgbToLinear(texture(colortex0, texcoord).rgb);
    albedo = mix(albedo, vec3(luminance(albedo)), ALBEDO_DESAT);

    // Particles and some entities arrive without a normal; a stored 0.5
    // reads back as a zero vector
    vec3 Nraw = texture(colortex1, texcoord).rgb * 2.0 - 1.0;
    vec3 N = dot(Nraw, Nraw) > 1e-6 ? normalize(Nraw) : vec3(0.0, 1.0, 0.0);
    vec4 data2 = texture(colortex2, texcoord);
    vec2 lm = data2.xy;
    float matId = data2.z * 255.0;
    bool terrain = data2.w > 0.5;
    float ao = texture(colortex3, texcoord).r;
    float aoSky = ao;

    vec3 worldPos = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz + cameraPosition;

    // Block light inside the grid: traced direct light from the strongest
    // lamps and the bounce volume as indirect; lightmap outside. The sky
    // visibility comes from the grid as well where it has an estimate,
    // gated by the lightmap so a cave below the grid's top stays dark.
    float skyVis = skyVisibility(lm);
#if SKIP_TRACE
    vec3 direct = vec3(0.0);
    vec3 bounce = vec3(0.0);
    vec3 blockRadiance = lightmapBlockLight(lm);
#else
    float inGrid = gridCoverage(worldPos);
    ivec3 tapBase;
    float tapW[8];
    volumeTaps(worldPos, N, tapBase, tapW);
    vec3 bounce = sampleBounce(tapBase, tapW) * BOUNCE_STRENGTH;
#if SKIP_DIRECT
    vec3 direct = vec3(0.0);
#else
    vec3 direct = directLight(worldPos, N, frameCounter, terrain);
#endif
    vec3 blockRadiance = mix(lightmapBlockLight(lm), direct + bounce, inGrid);
#if SKY_GRID_ENABLED
    float gridSky = sampleSky(tapBase, tapW, N, frameCounter);
    if (gridSky >= 0.0) {
        skyVis = mix(skyVis, gridSky * smoothstep(0.0, SKY_GRID_GATE, lm.y), inGrid);
        // The grid already darkens where the sky is hidden; the
        // screen-space term steps back there on the sky term alone
        aoSky = mix(ao, 1.0, AO_SKY_RELIEF * (1.0 - gridSky) * inGrid);
    }
#endif
#endif

#if DEBUG_VIEW == 10
    gl_FragData[0] = vec4(directDebug(worldPos, N, frameCounter), 1.0);
    return;
#elif DEBUG_VIEW == 21
    gl_FragData[0] = vec4(estimatorDebug(worldPos, N, frameCounter, pixelCell(worldPos, N)), 1.0);
    return;
#elif DEBUG_VIEW == 22
    gl_FragData[0] = vec4(rectDebug(worldPos, N, frameCounter, pixelCell(worldPos, N)), 1.0);
    return;
#elif DEBUG_VIEW == 23
    gl_FragData[0] = vec4(referenceDebug(worldPos, N, frameCounter), 1.0);
    return;
#elif DEBUG_VIEW == 24
    {
        ivec3 c = pixelCell(worldPos, N);
        uint v = voxelInside(c) ? texelFetch(voxelSampler, c, 0).r : 0u;
        vec3 dbg = srgbToLinear(texture(colortex0, texcoord).rgb) * 0.25;
        if (voxelSolid(v) && voxelPartial(v)) {
            bool agree = (v & (1u << 30)) != 0u;
            bool disagree = (v & (1u << 31)) != 0u;
            dbg = vec3(disagree ? 1.0 : 0.0, agree ? 1.0 : 0.0, (agree || disagree) ? 0.0 : 1.0);
        }
        gl_FragData[0] = vec4(dbg, 1.0);
        return;
    }
#elif DEBUG_VIEW == 14
    float cost = clamp(float(traceCost) / 256.0, 0.0, 1.0);
    vec3 heat = cost < 0.5 ? mix(vec3(0.0, 0.0, 0.4), vec3(0.0, 1.0, 0.0), cost * 2.0)
                           : mix(vec3(0.0, 1.0, 0.0), vec3(1.0, 0.0, 0.0), cost * 2.0 - 1.0);
    if (traceCost >= 256) heat = vec3(1.0);
    gl_FragData[0] = vec4(heat, 1.0);
    return;
#elif DEBUG_VIEW == 15
    if (texcoord.y > 0.5) {
        // One column per lamp of the list, the whole width being 512:
        // orange torch class, red fire and lava, magenta redstone, white
        // unknown; darkened when the lamp lies below the camera's block
        int lset = lightSet(frameCounter);
        int li = int(texcoord.x * float(LIGHTS_MAX));
        if (li >= int(lightCount(lset))) { gl_FragData[0] = vec4(vec3(0.05), 1.0); return; }
        uvec4 L = lightList.lights[lset * LIGHTS_MAX + li];
        int cc = voxelColorClass(L.w);
        vec3 c = cc == 1 ? vec3(1.0, 0.6, 0.1) : (cc == 2 ? vec3(1.0, 0.0, 0.0) : (cc == 3 ? vec3(1.0, 0.0, 1.0) : vec3(1.0)));
        if (int(L.y) < VOXEL_HALF) c *= 0.3;
        gl_FragData[0] = vec4(c, 1.0);
        return;
    }
    // Red: the block's voxel emits and is not solid, so the block itself
    // came in as a lamp. Magenta: it emits and is solid, so a lamp's
    // triangles landed in a solid block's cell. Green added when the
    // G-buffer id of the pixel is an emitter as well.
    ivec3 li = pixelCell(worldPos, N);
    uint lv = voxelInside(li) ? texelFetch(voxelSampler, li, 0).r : 0u;
    float em = voxelEmission(lv) > 0 ? 1.0 : 0.0;
    int mi = int(matId + 0.5);
    float gb = (mi == 1 || mi == 6 || mi == 7 || mi == 11) ? 0.6 : 0.0;
    vec3 dbg = vec3(em, gb, em > 0.0 ? (voxelSolid(lv) ? 1.0 : 0.0) : 0.1);
    if (lampBinOverflow(lampBinOf(worldPos - vec3(voxelOrigin(cameraPosition))))) dbg = mix(dbg, vec3(0.0, 1.0, 1.0), 0.6);
    gl_FragData[0] = vec4(dbg, 1.0);
    return;
#elif DEBUG_VIEW == 16
    ivec3 ci = pixelCell(worldPos, N);
    vec4 sc = voxelInside(ci) ? texelFetch(voxelColorSampler, ci, 0) : vec4(0.0);
    int sid = int(sc.r * 255.0 + 0.5);
    bool unmapped = sc.g > 0.5;
    int gid = int(matId + 0.5);
    vec3 dbg;
    if (sc.a < 0.5) dbg = vec3(0.0, 0.0, 0.5);
    else if (unmapped) dbg = gid == 0 ? vec3(1.0) : vec3(1.0, 1.0, 0.0);
    else if (sid == gid) dbg = vec3(1.0);
    else if (sid == 1 || sid == 6 || sid == 7 || sid == 11) dbg = vec3(1.0, 0.0, 0.0);
    else dbg = vec3(0.0, 1.0, 0.0);
    gl_FragData[0] = vec4(dbg, 1.0);
    return;
#elif DEBUG_VIEW == 17
    gl_FragData[0] = vec4(guideDebug(worldPos, N, frameCounter), 1.0);
    return;
#elif DEBUG_VIEW == 18
    gl_FragData[0] = vec4(vec3(skyVis), 1.0);
    return;
#elif DEBUG_VIEW == 19
    {
        ivec3 cb; float cw[8];
        volumeTaps(worldPos, N, cb, cw);
        gl_FragData[0] = vec4(vec3(sampleSkyCount(cb, cw, frameCounter)), 1.0);
        return;
    }
#elif DEBUG_VIEW == 20
    {
        ivec3 cb; float cw[8];
        volumeTaps(worldPos, N, cb, cw);
        int best = 0;
        for (int k = 1; k < 8; k++) if (cw[k] > cw[best]) best = k;
        ivec3 c = cb + volumeCorner(best);
        vec3 dbg = vec3(0.2);
        if (voxelInside(c)) {
            int sset = skySet(frameCounter);
            dbg = vec3(float(min(skyResets(sset, c), 6u)) / 6.0, float(skyCount(sset, c)) / float(SKY_HISTORY), 0.0);
        }
        gl_FragData[0] = vec4(dbg, 1.0);
        return;
    }
#elif DEBUG_VIEW == 8
    gl_FragData[0] = vec4(bounce, 1.0);
    return;
#elif DEBUG_VIEW == 4 || DEBUG_VIEW == 5
    // 4: voxel just behind the surface. 5: voxel half a block in front, the
    // one the volume taps read. White = full cube, light grey = partial
    // block, grey = solid by id without any triangle, green = leaves,
    // purple = entity box, coloured = emitter, black = air, blue = outside
    // the grid.
#if DEBUG_VIEW == 4
    ivec3 vi = ivec3(floor(worldPos - N * 0.5)) - voxelOrigin(cameraPosition);
#else
    ivec3 vi = ivec3(floor(worldPos + N * 0.5)) - voxelOrigin(cameraPosition);
#endif
    uint v = voxelInside(vi) ? texelFetch(voxelSampler, vi, 0).r : 0u;
    vec3 dbg = vec3(0.0);
    if (voxelSolid(v)) dbg = vec3(0.3);
    if (voxelOccluder(v)) dbg = voxelFull(v) ? vec3(1.0) : vec3(0.6);
    if (voxelLeaves(v)) dbg = vec3(0.2, 0.8, 0.2);
    if (voxelEntity(v)) dbg = vec3(0.7, 0.2, 0.8);
    if (voxelEmission(v) > 0) dbg = emissionColor(voxelColorClass(v));
    if (!voxelInside(vi)) dbg = vec3(0.0, 0.0, 0.5);
    gl_FragData[0] = vec4(dbg, 1.0);
    return;
#endif

    // Climate: below 0.15 this version snows; frozen ground reads as dry
    float cold = smoothstep(0.20, 0.08, temperature);
    float wet = hand ? 0.0 : max(BASE_WETNESS, wetness) * (1.0 - cold);

    Material m = materialFromId(matId);
    applyWetness(m, albedo, wet);

    vec3 V = -viewDirW;
    float F = fresnelWeight(N, V, m);
    vec3 color = shadeSurface(albedo * (1.0 - F), N, lm, matId, day, ao, blockRadiance, skyVis, aoSky);
    color += shadeSpecular(N, V, m, F, skyVis, day, aoSky);

    // A texel that is not finite would spread through the bloom mip chain
    // and the fog march; a black pixel is invisible
    if (any(isnan(color)) || any(isinf(color))) color = vec3(0.0);

    gl_FragData[0] = vec4(color, 1.0);
}