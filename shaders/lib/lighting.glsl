#ifndef LIGHTING_GLSL
#define LIGHTING_GLSL
#include "/lib/settings.glsl"
#include "/lib/atmosphere.glsl"
#include "/lib/material.glsl"
#include "/lib/voxel.glsl"
#include "/lib/lamp.glsl"

float skyVisibility(vec2 lm) { return pow(lm.y, 1.6); }

// Block light as the lightmap knows it, in the units of the traced term;
// used outside the voxel grid and for forward-shaded translucents. The
// level implies a Manhattan distance to a torch, which is scaled to a
// Euclidean one, and the torch's irradiance there is taken with the cosine
// averaged over the hemisphere. LIGHTMAP_MATCH stands in for the bounce
// and is the knob for the seam at the grid edge.
vec3 lightmapBlockLight(vec2 lm) {
    if (lm.x < 0.02) return vec3(0.0);
    float d = max(14.0 - 15.0 * lm.x, 0.0) * 0.75;
    uint torch = packVoxel(false, 14, 1);
    return lampIntensity(torch) * lampFalloff(d * d, 0.5) * LPV_EMISSION * DIRECT_STRENGTH * LIGHTMAP_MATCH;
}

// Overcast diffuse lighting: no direct light at all. Hemispheric ambient
// weighted by sky visibility and AO, plus block light radiance from whichever
// source the caller has (LPV or lightmap), plus emissives.
// ao occludes the block light, aoSky the sky term
vec3 shadeSurface(vec3 albedo, vec3 wnormal, vec2 lm, float matId, float day, float ao, vec3 blockRadiance, float skyVis, float aoSky) {
    float up = wnormal.y * 0.5 + 0.5;

    vec3 hemi = mix(GROUND_BOUNCE, SKY_ZENITH, up);
    hemi *= 0.65 + 0.35 * max(wnormal.y, 0.0);

    vec3 ambient = hemi * skyVis * ambientScale(day) * aoSky;
    ambient += vec3(0.002, 0.0025, 0.0035) * aoSky;

    vec3 block = blockRadiance * BLOCKLIGHT_STRENGTH * mix(1.0, ao, AO_BLOCKLIGHT);

    vec3 color = albedo * (ambient + block);

    int i = int(matId + 0.5);
    if (i == 1 || i == 6 || i == 7) {
        int c = i == 1 ? 1 : (i == 6 ? 2 : 3);
        // Only the bright texels of an emissive block emit: the flame of a
        // torch, not its stick. The ramp runs over sRGB 0.6 to 0.9 of the
        // brightest channel, here in linear light. Tied to LPV_EMISSION so
        // the lamp body and its pool on the floor scale together.
        float peak = max(albedo.r, max(albedo.g, albedo.b));
        float mask = smoothstep(0.30, 0.75, peak);
        color += albedo * emissionColor(c) * LPV_EMISSION * EMISSION_STRENGTH * mask;
    } else if (i == 11) {
        // A floodlight is a glowing panel whatever its texture; the body
        // brightens with the root of the strength so it does not swallow
        // the bloom
        color += emissionColor(0) * LPV_EMISSION * EMISSION_STRENGTH * sqrt(FLOOD_STRENGTH);
    }
    return color;
}

vec3 shadeSurface(vec3 albedo, vec3 wnormal, vec2 lm, float matId, float day, float ao, vec3 blockRadiance) {
    return shadeSurface(albedo, wnormal, lm, matId, day, ao, blockRadiance, skyVisibility(lm), ao);
}

vec3 shadeSurface(vec3 albedo, vec3 wnormal, vec2 lm, float matId, float day) {
    return shadeSurface(albedo, wnormal, lm, matId, day, 1.0, lightmapBlockLight(lm));
}

// Fresnel weight shared by the reflection and the matching diffuse loss.
// V points from surface to eye.
float fresnelWeight(vec3 N, vec3 V, Material m) {
    float NoV = max(dot(N, V), 1e-3);
    // Rough surfaces have no grazing mirror: the peak is capped by gloss (Lagarde 2014)
    float peak = max(1.0 - m.roughness, m.f0);
    float F = m.f0 + (peak - m.f0) * pow(1.0 - NoV, 5.0);
    // Soaked porous matter scatters instead of reflecting
    return F * (1.0 - 0.9 * m.porosity);
}

// Reflection of the overcast dome. The dome is smooth and analytic, so a wide
// lobe is approximated by bending the reflected ray towards the normal.
vec3 shadeSpecular(vec3 N, vec3 V, Material m, float F, float skyVis, float day, float ao) {
    if (m.f0 <= 0.0 || F <= 0.0) return vec3(0.0);
    vec3 R = reflect(-V, N);
    float a = m.roughness * m.roughness;
    vec3 Rb = normalize(mix(R, N, a));

    float NoV = max(dot(N, V), 0.0);
    float so = clamp(pow(NoV + ao, exp2(-16.0 * m.roughness - 1.0)) - 1.0 + ao, 0.0, 1.0);

    return overcastSky(Rb, day) * F * skyVis * so;
}

#endif

