#version 330 compatibility
#include "/lib/settings.glsl"
#include "/lib/common.glsl"

// Ground-truth ambient occlusion (Jimenez et al. 2016), horizon-based in
// view space. Noisy output; deferred1 blurs it, deferred2 consumes it.

/*
const int colortex3Format = R16; // ambient occlusion
*/

uniform sampler2D colortex1;
uniform sampler2D depthtex0;
uniform sampler2D depthtex2;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelView;
uniform float viewWidth;
uniform float viewHeight;

in vec2 texcoord;

vec3 viewPosAt(vec2 uv) {
    float d = texture(depthtex0, uv).r;
    return screenToView(vec3(uv, d), gbufferProjectionInverse);
}

// Integral of the cosine-weighted visible arc of one half-slice
float arcIntegral(float h, float n) {
    return -cos(2.0 * h - n) + cos(n) + 2.0 * h * sin(n);
}

// Horizon cosine along one direction, with distance falloff
float horizonAlong(vec2 uv, vec3 P, vec3 V, float prev) {
    vec3 D = viewPosAt(uv) - P;
    float len = length(D);
    float c = clamp(dot(D, V) / max(len, 1e-4), -1.0, 1.0);
    float fall = clamp((len - AO_RADIUS * 0.5) / (AO_RADIUS * 0.5), 0.0, 1.0);
    return max(prev, mix(c, -1.0, fall));
}

/* DRAWBUFFERS:3 */
void main() {
    float depth = texture(depthtex0, texcoord).r;
#if AO_ENABLED == 0 || SKIP_SCREEN
    gl_FragData[0] = vec4(1.0);
    return;
#endif
    // Sky, and the hand (present in depthtex0, absent from depthtex2)
    if (depth >= 1.0 || abs(texture(depthtex2, texcoord).r - depth) > 1e-7) {
        gl_FragData[0] = vec4(1.0);
        return;
    }

    vec3 P = screenToView(vec3(texcoord, depth), gbufferProjectionInverse);

    // Beyond this the kernel covers a handful of texels and fog owns the image
    float fade = smoothstep(96.0, 48.0, -P.z);
    if (fade <= 0.0) {
        gl_FragData[0] = vec4(1.0);
        return;
    }

    vec3 N = normalize(mat3(gbufferModelView) * (texture(colortex1, texcoord).rgb * 2.0 - 1.0));
    vec3 V = normalize(-P);

    float radiusPx = AO_RADIUS * gbufferProjection[1][1] * viewHeight * 0.5 / max(-P.z, 0.1);
    radiusPx = clamp(radiusPx, 3.0, float(AO_RADIUS_PX));
    vec2 texel = 1.0 / vec2(viewWidth, viewHeight);

    float noiseA = ign(gl_FragCoord.xy);
    float noiseB = ign(gl_FragCoord.xy + vec2(37.0, 71.0));

    float vis = 0.0;
    for (int s = 0; s < AO_SLICES; s++) {
        float phi = (float(s) + noiseA) * PI / float(AO_SLICES);
        vec2 dir2 = vec2(cos(phi), sin(phi));
        vec3 dir3 = vec3(dir2, 0.0);
        vec3 ortho = normalize(dir3 - dot(dir3, V) * V);
        vec3 axis = cross(ortho, V);

        vec3 projN = N - axis * dot(N, axis);
        float projLen = length(projN);
        if (projLen < 1e-4) { vis += 1.0; continue; }
        float sgn = sign(dot(ortho, projN));
        float cosN = clamp(dot(projN, V) / projLen, -1.0, 1.0);
        float n = sgn * acos(cosN);

        float hNeg = -1.0;
        float hPos = -1.0;
        for (int i = 0; i < AO_STEPS; i++) {
            float t = (float(i) + noiseB) / float(AO_STEPS);
            t *= t;
            vec2 off = dir2 * max(t * radiusPx, 1.0) * texel;
            hNeg = horizonAlong(texcoord - off, P, V, hNeg);
            hPos = horizonAlong(texcoord + off, P, V, hPos);
        }

        float h0 = n + max(-acos(hNeg) - n, -PI * 0.5);
        float h1 = n + min( acos(hPos) - n,  PI * 0.5);
        vis += projLen * 0.25 * (arcIntegral(h0, n) + arcIntegral(h1, n));
    }
    vis /= float(AO_SLICES);
    vis = pow(clamp(vis, 0.0, 1.0), AO_STRENGTH);
    vis = mix(1.0, vis, fade);

    gl_FragData[0] = vec4(vis, 0.0, 0.0, 1.0);
}