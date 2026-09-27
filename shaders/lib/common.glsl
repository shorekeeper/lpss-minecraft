#ifndef COMMON_GLSL
#define COMMON_GLSL

#define PI 3.14159265359

float luminance(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

vec3 srgbToLinear(vec3 c) { return pow(max(c, 0.0), vec3(2.2)); }
vec3 linearToSrgb(vec3 c) { return pow(max(c, 0.0), vec3(1.0 / 2.2)); }

// screenPos.xyz in [0,1]; returns view-space position
vec3 screenToView(vec3 screenPos, mat4 projInv) {
    vec4 ndc = vec4(screenPos * 2.0 - 1.0, 1.0);
    vec4 v = projInv * ndc;
    return v.xyz / v.w;
}

// Interleaved gradient noise, cheap per-pixel dither
float ign(vec2 px) {
    return fract(52.9829189 * fract(0.06711056 * px.x + 0.00583715 * px.y));
}

// Lightmap texcoord after gl_TextureMatrix[1] sits in [1/32, 31/32]; map to [0,1]
vec2 normalizeLightmap(vec2 lm) {
    return clamp((lm - 0.03125) / 0.9375, 0.0, 1.0);
}

// sunAngle: 0 = sunrise, 0.25 = noon, 0.5 = sunset, 0.75 = midnight.
// The overcast sky never shows the sun; this only scales overall brightness.
float daylight(float sunAngle) {
    float elevation = sin(sunAngle * 2.0 * PI);
    return smoothstep(-0.10, 0.18, elevation);
}

#endif

