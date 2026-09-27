#version 330 compatibility
#include "/lib/settings.glsl"
#include "/lib/common.glsl"

/*
const bool colortex5MipmapEnabled = true;
*/

uniform sampler2D colortex0;
uniform sampler2D colortex5;
uniform float frameTimeCounter;
uniform float viewWidth;
uniform float viewHeight;

in vec2 texcoord;

// Sum of the thresholded scene's mip levels 2 to 6. Each level is read with
// a tent of five taps so the box footprint of a level does not show; the
// coarse levels give the long tail, the fine ones the core of the glow.
vec3 bloom() {
    vec2 texel = 1.0 / vec2(viewWidth, viewHeight);
    vec3 sum = vec3(0.0);
    for (int level = 2; level <= 6; level++) {
        float l = float(level);
        vec2 o = texel * exp2(l) * 0.75;
        vec3 s = textureLod(colortex5, texcoord, l).rgb * 2.0;
        s += textureLod(colortex5, texcoord + vec2( o.x,  o.y), l).rgb;
        s += textureLod(colortex5, texcoord + vec2(-o.x,  o.y), l).rgb;
        s += textureLod(colortex5, texcoord + vec2( o.x, -o.y), l).rgb;
        s += textureLod(colortex5, texcoord + vec2(-o.x, -o.y), l).rgb;
        sum += s / 6.0;
    }
    return sum / 5.0;
}

// Soft shoulder with low contrast: greys stay grey, lamps roll off gently
vec3 tonemap(vec3 x) {
    x *= EXPOSURE;
    return x / (x + 0.6);
}

void main() {
    vec3 color = texture(colortex0, texcoord).rgb;

#if DEBUG_VIEW != 0
    gl_FragColor = vec4(linearToSrgb(color), 1.0);
    return;
#endif

    color += bloom() * BLOOM_STRENGTH;
    color = tonemap(color);
    color = linearToSrgb(color);

    // Lift blacks towards a cool tint; fades out in the highlights
    color += SHADOW_TINT * SHADOW_LIFT * (1.0 - color);

    // Cool cast: slate rather than neutral grey
    color *= vec3(0.94, 0.98, 1.04);

    // White balance towards blue, brightness kept
    vec3 cold = mix(vec3(1.0), vec3(0.84, 0.94, 1.14), COLD_TINT);
    color *= cold / luminance(cold);

    // Desaturate, keeping the warm lamps more saturated than the rest
    float lum = luminance(color);
    float warmth = clamp((color.r - color.b) * 3.0, 0.0, 1.0);
    color = mix(color, vec3(lum), DESATURATION * (1.0 - 0.6 * warmth));

    // Fine animated grain, stronger in the darks
    float g = ign(gl_FragCoord.xy + fract(frameTimeCounter * 7.13) * 137.0) - 0.5;
    color += g * GRAIN_AMOUNT * (0.5 + 0.5 * (1.0 - lum));

    // Gentle vignette
    vec2 uv = texcoord * 2.0 - 1.0;
    color *= 1.0 - dot(uv, uv) * 0.10;

    gl_FragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}

