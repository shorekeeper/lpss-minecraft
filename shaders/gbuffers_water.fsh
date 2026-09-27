#version 330 compatibility
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/lighting.glsl"
#include "/lib/volume.glsl"
#include "/lib/entity_tris.glsl"
#include "/lib/direct.glsl"

// Translucents render after deferred, so they are shaded forward here and
// blended over the lit scene. Inside the grid the block light is the
// traced direct term and the bounce volume, as for the opaque surfaces;
// the sky term and the occlusion stay with the lightmap. Water and glass
// are air to the grid, so the ray starts in the cell in front of the
// surface like on any other block.

uniform sampler2D gtexture;
uniform float sunAngle;
uniform int frameCounter;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 vcolor;
in vec3 wnormal;
in vec3 cpos;
in float matId;
flat in float terrain;

/* DRAWBUFFERS:0 */
void main() {
    vec4 albedo = texture(gtexture, texcoord) * vcolor;
    if (albedo.a < 0.01) discard;

    float day = daylight(sunAngle);
    vec3 N = normalize(wnormal);
    vec2 lm = normalizeLightmap(lmcoord);
    vec3 worldPos = cpos + cameraPosition;

    vec3 blockRadiance = lightmapBlockLight(lm);
#if !SKIP_TRACE
    float inGrid = gridCoverage(worldPos);
    if (inGrid > 0.0) {
        ivec3 tapBase;
        float tapW[8];
        volumeTaps(worldPos, N, tapBase, tapW);
        vec3 bounce = sampleBounce(tapBase, tapW) * BOUNCE_STRENGTH;
#if SKIP_DIRECT
        vec3 direct = vec3(0.0);
#else
        vec3 direct = directLight(worldPos, N, frameCounter, terrain > 0.5);
#endif
        blockRadiance = mix(blockRadiance, direct + bounce, inGrid);
    }
#endif

    vec3 lit = shadeSurface(srgbToLinear(albedo.rgb), N, lm, matId, day, 1.0, blockRadiance);

    // Water: pull towards the sky colour and keep it flat and oily
    if (abs(matId - 2.0) < 0.5) {
        lit = mix(lit, SKY_ZENITH * ambientScale(day) * 0.6, 0.55);
        albedo.a = max(albedo.a, 0.75);
    }
    gl_FragData[0] = vec4(lit, albedo.a);
}