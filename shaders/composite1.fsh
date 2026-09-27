#version 330 compatibility
#include "/lib/settings.glsl"
#include "/lib/common.glsl"

// Adds the in-scattered block light to the scene and writes the bloom
// source. The volumetric was marched with one of 16 step offsets per pixel
// of a 4x4 tile; an exact 4x4 texel box sums the whole set. The taps are
// weighed by the length of their march, the depth capped at
// VOLUMETRIC_RANGE, so a foreground surface does not take the fog behind
// it while the sky and a hill beyond the range, whose marches are the
// same, weigh the same: a weight on the raw depth would leave the sky
// beside the hill with part of the set and draw the hill's outline into
// the fog. The bloom
// source is the part of the result above BLOOM_THRESHOLD, before the
// tonemap; texels that are not finite are dropped and the brightness is
// capped, since the mip chain spreads a single texel wide.

/*
const int colortex5Format = RGBA16F;
*/

uniform sampler2D colortex0;
uniform sampler2D colortex4;
uniform sampler2D depthtex0;
uniform float near;
uniform float far;

in vec2 texcoord;

float linearDepth(float d) {
    return 2.0 * near * far / (far + near - (d * 2.0 - 1.0) * (far - near));
}

/* DRAWBUFFERS:05 */
void main() {
    ivec2 px = ivec2(gl_FragCoord.xy);
    vec3 color = texelFetch(colortex0, px, 0).rgb;
    float zc = min(linearDepth(texelFetch(depthtex0, px, 0).r), VOLUMETRIC_RANGE);

    vec3 sum = vec3(0.0);
    float wsum = 0.0;
    for (int y = -1; y <= 2; y++) {
        for (int x = -1; x <= 2; x++) {
            ivec2 p = px + ivec2(x, y);
            float z = min(linearDepth(texelFetch(depthtex0, p, 0).r), VOLUMETRIC_RANGE);
            float w = 1.0 / (1.0 + 8.0 * abs(z - zc) / zc);
            sum += texelFetch(colortex4, p, 0).rgb * w;
            wsum += w;
        }
    }
    color += sum / max(wsum, 1e-4);

    vec3 c = color;
    if (any(isnan(c)) || any(isinf(c))) c = vec3(0.0);
    c = min(c, vec3(64.0));
    float peak = max(c.r, max(c.g, c.b));
    float k = max(peak - BLOOM_THRESHOLD, 0.0) / max(peak, 1e-4);

    gl_FragData[0] = vec4(color, 1.0);
    gl_FragData[1] = vec4(c * k, 1.0);
}

