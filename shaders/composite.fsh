#version 330 compatibility
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/atmosphere.glsl"
#include "/lib/volume.glsl"
#include "/lib/snow.glsl"

// Fog over the lit scene, translucents included (depthtex0). The analytic
// media give the extinction and the sky-coloured haze. The block light that
// reaches the air, held in the fog volume of lib/fogvol.glsl, is scattered
// in along the view ray and written to its own buffer; composite1 sums the
// per-pixel step offsets over a 4x4 tile and adds it.

/*
const int colortex4Format = RGBA16F; // in-scattered block light
*/

uniform sampler2D colortex0;
uniform sampler2D depthtex0;
uniform sampler3D fogSamplerA;
uniform sampler3D fogSamplerB;
uniform sampler3D fogDirSamplerA;
uniform sampler3D fogDirSamplerB;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform float sunAngle;
uniform float far;
uniform int frameCounter;

in vec2 texcoord;

// Irradiance of the air at p, from the volume written this frame, and the
// mean direction the light travels in, its length the share of the light
// that arrives from one side
vec3 fogIrradiance(vec3 p, out vec3 flow) {
    vec3 uv = (p - vec3(voxelOrigin(cameraPosition))) / float(VOXEL_SIZE);
    bool even = (frameCounter & 1) == 0;
    vec4 c = even ? texture(fogSamplerA, uv) : texture(fogSamplerB, uv);
    vec3 d = even ? texture(fogDirSamplerA, uv).rgb : texture(fogDirSamplerB, uv).rgb;
    float lum = luminance(c.rgb);
    flow = lum > 1e-6 ? d / lum : vec3(0.0);
    float len = length(flow);
    if (len > 1.0) flow /= len;
    return c.rgb * LPV_EMISSION;
}

vec3 fogIrradiance(vec3 p) {
    vec3 flow;
    return fogIrradiance(p, flow);
}

// Henyey-Greenstein phase relative to isotropic, cosT the cosine between
// the light's direction and the scattered one
float hgPhase(float cosT, float g) {
    float d = 1.0 + g * g - 2.0 * g * cosT;
    return (1.0 - g * g) / (d * sqrt(d));
}

// In-scattered block light along ro + rd * t up to dist. Each step takes
// the fog density there, the irradiance of the air and the transmittance
// accumulated so far. Radiance per unit length is the scattering
// coefficient times the irradiance over 4 pi, times the phase: forward
// scattering along the light's mean direction for the directed share of
// the light, isotropic for the rest. VOLUMETRIC_DENSITY adds medium to
// scatter in without adding to the extinction.
vec3 volumetricLight(vec3 ro, vec3 rd, float dist, float jitter) {
    float tEnd = min(dist, VOLUMETRIC_RANGE);
    if (tEnd <= 0.1) return vec3(0.0);
    // The step is the same for every pixel and the surface only cuts the
    // march short: a step scaled to the surface would sample the air in
    // front of the camera at different points behind every row of a
    // distant hill, and draw its contours in the fog
    float dt = VOLUMETRIC_RANGE / float(VOLUMETRIC_STEPS);
    vec3 sum = vec3(0.0);
    float od = 0.0;
    for (int i = 0; i < VOLUMETRIC_STEPS; i++) {
        float t = (float(i) + jitter) * dt;
        if (t > tEnd) break;
        vec3 p = ro + rd * t;
        float dens = heightFogDensity(p.y) + distanceFogDensity(t, far);
        od += dens * dt;
        float cover = gridCoverage(p);
        if (cover <= 0.0) continue;
        vec3 flow;
        vec3 irr = fogIrradiance(p, flow);
        float aniso = length(flow);
        float phase = 1.0;
        if (aniso > 1e-3) {
            // Scattered towards the camera, so against the view ray
            float cosT = -dot(flow, rd) / aniso;
            phase = mix(1.0, hgPhase(cosT, VOLUMETRIC_ANISOTROPY), aniso);
        }
        sum += irr * phase * cover * (dens + VOLUMETRIC_DENSITY) * exp(-od) * dt;
    }
    return sum * (VOLUMETRIC_STRENGTH / 12.5663706144);
}

/* DRAWBUFFERS:04 */
void main() {
    vec3 color = texture(colortex0, texcoord).rgb;
    float depth = texture(depthtex0, texcoord).r;

#if DEBUG_VIEW != 0
    gl_FragData[0] = vec4(color, 1.0);
    gl_FragData[1] = vec4(0.0, 0.0, 0.0, 1.0);
    return;
#endif

    float day = daylight(sunAngle);
    vec3 viewPos = screenToView(vec3(texcoord, depth), gbufferProjectionInverse);
    float dist = depth >= 1.0 ? far : length(viewPos);
    vec3 rd = mat3(gbufferModelViewInverse) * normalize(viewPos);

    if (depth < 1.0) {
        float od = heightFogDepth(cameraPosition, rd, dist) + distanceFogDepth(dist, far);
        float fog = 1.0 - exp(-od);
        color = mix(color, fogColor(rd, day), fog);
    }

#if SNOW_ENABLED && !SKIP_SCREEN
    color = snowVeil(color, rd, dist, day);
    mat3 cam = mat3(gbufferModelViewInverse);
    color = snowfall(color, cameraPosition, rd, cam[0], cam[1], dist, day, far, frameCounter);
#endif

    // One of 16 step offsets per pixel of a 4x4 tile; composite1's box
    // sums the set
    ivec2 slot = ivec2(gl_FragCoord.xy) & 3;
    float jitter = (float(slot.x + slot.y * 4) + 0.5) / 16.0;
#if SKIP_SCREEN
    vec3 vol = vec3(0.0);
#else
    vec3 vol = volumetricLight(cameraPosition, rd, dist, jitter);
#endif

    gl_FragData[0] = vec4(color, 1.0);
    gl_FragData[1] = vec4(vol, 1.0);
}

